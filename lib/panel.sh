php_modules_install() {
  local base=php8.3
  local core_ok=0
  apt-get install -y "$base-cli" "$base-fpm" "$base-gd" "$base-mysql" "$base-mbstring" \
    "$base-bcmath" "$base-xml" "$base-curl" "$base-zip" "$base-intl" "$base-sqlite3" >>"$INSTALL_LOG" 2>&1 && core_ok=1
  apt-get install -y "$base-redis" >>"$INSTALL_LOG" 2>&1 || apt-get install -y php-redis >>"$INSTALL_LOG" 2>&1 || true
  if [ "$core_ok" = "0" ] || ! dpkg -s "$base-fpm" >/dev/null 2>&1; then
    return 1
  fi
}

panel_phase() {
  banner "Phase 3/8 - Panel stack (PHP, MariaDB, Redis, Nginx)"
  export DEBIAN_FRONTEND=noninteractive
  PANEL_FQDN="$PANEL_SUBDOMAIN.$DOMAIN"
  NODE_FQDN="$NODE_SUBDOMAIN.$DOMAIN"

  log "Installing PHP 8.3 and extensions..."
  php_modules_install || die "Failed to install PHP 8.3 modules."

  log "Installing MariaDB, Redis and Nginx..."
  apt-get install -y mariadb-server mariadb-client redis-server nginx >>"$INSTALL_LOG" 2>&1 \
    || die "Failed to install database/webserver packages."

  log "Starting services..."
  ensure_service mariadb 3 || die "MariaDB failed to start."
  ensure_service redis-server 3 || die "Redis failed to start."
  ensure_service php8.3-fpm 3 || die "PHP-FPM failed to start."
  ensure_service nginx 3 || die "Nginx failed to start."

  log "Creating panel database..."
  local db_password
  if [ -f "$SECRETS_FILE" ]; then
    set -a
    . "$SECRETS_FILE"
    set +a
  fi
  db_password=${DB_PASSWORD:-$(random_hex 16)}
  mysql -e "CREATE DATABASE IF NOT EXISTS pelican CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>>"$INSTALL_LOG"
  mysql -e "CREATE USER IF NOT EXISTS 'pelican'@'127.0.0.1' IDENTIFIED BY '$db_password';" 2>>"$INSTALL_LOG"
  mysql -e "CREATE USER IF NOT EXISTS 'pelican'@'localhost' IDENTIFIED BY '$db_password';" 2>>"$INSTALL_LOG"
  mysql -e "GRANT ALL PRIVILEGES ON pelican.* TO 'pelican'@'127.0.0.1';" 2>>"$INSTALL_LOG"
  mysql -e "GRANT ALL PRIVILEGES ON pelican.* TO 'pelican'@'localhost';" 2>>"$INSTALL_LOG"
  mysql -e "FLUSH PRIVILEGES;" 2>>"$INSTALL_LOG"
  mkdir -p "$PI_ROOT"
  echo "DB_PASSWORD=$db_password" > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"

  log "Downloading Pelican Panel..."
  mkdir -p "$PANEL_DIR"
  curl -fsSL -m 120 -o /tmp/panel.tar.gz "https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz" >>"$INSTALL_LOG" 2>&1 \
    || die "Failed to download panel. Retry when GitHub is reachable."
  tar -xzf /tmp/panel.tar.gz -C "$PANEL_DIR" >>"$INSTALL_LOG" 2>&1 || die "Failed to extract panel."

  log "Installing Composer..."
  curl -fsSL -m 60 -o /tmp/composer-setup.php "https://getcomposer.org/installer" >>"$INSTALL_LOG" 2>&1 \
    || die "Failed to download composer installer."
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet >>"$INSTALL_LOG" 2>&1 \
    || die "Failed to install composer."

  log "Installing panel dependencies (this can take several minutes)..."
  (cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction) >>"$INSTALL_LOG" 2>&1 \
    || die "Composer install failed."

  log "Writing panel environment..."
  write_panel_env "$db_password" || die "Failed to write panel .env"
  (cd "$PANEL_DIR" && php artisan key:generate --force) >>"$INSTALL_LOG" 2>&1 || true

  log "Migrating database and seeding eggs..."
  (cd "$PANEL_DIR" && php artisan migrate --seed --force) >>"$INSTALL_LOG" 2>&1 \
    || log_err "Database migrate failed - the web installer at /installer will retry it."

  log "Setting permissions..."
  chown -R www-data:www-data "$PANEL_DIR"
  chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

  log "Writing nginx configuration..."
  write_nginx_config
  rm -f /etc/nginx/sites-enabled/default
}

write_panel_env() {
  local db_password=$1
  local redis_client=predis
  if dpkg -s php8.3-redis >/dev/null 2>&1 || dpkg -s php-redis >/dev/null 2>&1; then
    redis_client=phpredis
  fi
  cat > "$PANEL_DIR/.env" <<EOF
APP_ENV=production
APP_ENVIRONMENT=production
APP_DEBUG=false
APP_INSTALLED=false
APP_URL=https://$PANEL_FQDN
APP_TIMEZONE=${TIMEZONE:-UTC}
APP_LOCALE=en
APP_SERVICE_AUTHOR=auto-installer
TRUSTED_PROXIES=*

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=pelican
DB_USERNAME=pelican
DB_PASSWORD=$db_password

CACHE_STORE=redis
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_CLIENT=$redis_client
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=null

MAIL_MAILER=log
EOF
  chown www-data:www-data "$PANEL_DIR/.env"
  chmod 600 "$PANEL_DIR/.env"
}

write_nginx_config() {
  cat > /etc/nginx/sites-available/pelican.conf <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $PANEL_FQDN;

    root /var/www/pelican/public;
    index index.php;

    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/pelican/tls/panel/fullchain.pem;
    ssl_certificate_key /etc/pelican/tls/panel/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
}

nginx_enable_phase() {
  banner "Phase 6/8 - Finalizing nginx behind tunnel"
  if [ ! -f "$PANEL_TLS_DIR/panel/fullchain.pem" ]; then
    log "Panel TLS certificate not found yet - waiting for Cloudflare phase to issue it."
    return 1
  fi
  write_nginx_config
  ensure_service nginx 3 || log_err "Nginx failed to start - check /var/log/nginx/pelican.app-error.log"
}
