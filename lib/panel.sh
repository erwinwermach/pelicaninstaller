detect_php_version() {
  apt-get update -y >>"$INSTALL_LOG" 2>&1 || true
  local v
  for v in 8.5 8.4 8.3; do
    if apt-cache show "php$v-fpm" >/dev/null 2>&1 && [ "$(apt-cache policy "php$v-fpm" 2>/dev/null | grep -c Candidate)" != "0" ]; then
      if ! apt-cache policy "php$v-fpm" 2>/dev/null | grep -q 'Candidate: (none)'; then
        echo "$v"
        return 0
      fi
    fi
  done
  echo ""
}

php_modules_install() {
  local base="php$(panel_php_version)"
  local core_ok=0
  apt-get install -y "$base-cli" "$base-fpm" "$base-gd" "$base-mysql" "$base-mbstring" \
    "$base-bcmath" "$base-xml" "$base-curl" "$base-zip" "$base-intl" "$base-sqlite3" >>"$INSTALL_LOG" 2>&1 && core_ok=1
  if [ "$core_ok" = "0" ]; then
    for v in 8.5 8.4 8.3; do
      base="php$v"
      apt-get install -y "$base-cli" "$base-fpm" "$base-gd" "$base-mysql" "$base-mbstring" \
        "$base-bcmath" "$base-xml" "$base-curl" "$base-zip" "$base-intl" "$base-sqlite3" >>"$INSTALL_LOG" 2>&1 && { core_ok=1; break; }
    done
  fi
  apt-get install -y "$base-redis" >>"$INSTALL_LOG" 2>&1 || apt-get install -y php-redis >>"$INSTALL_LOG" 2>&1 || true
  if [ "$core_ok" = "0" ] || ! dpkg -s "$base-fpm" >/dev/null 2>&1; then
    return 1
  fi
}

panel_phase() {
  banner "Phase 3 - Panel stack (PHP, MariaDB, Redis, Nginx)"
  export DEBIAN_FRONTEND=noninteractive
  PANEL_SUBDOMAIN=${PANEL_SUBDOMAIN:-panel}
  NODE_SUBDOMAIN=${NODE_SUBDOMAIN:-node}
  DOMAIN=${DOMAIN:-example.com}
  PANEL_FQDN="$PANEL_SUBDOMAIN.$DOMAIN"
  NODE_FQDN="$NODE_SUBDOMAIN.$DOMAIN"

  log "Detecting available PHP version..."
  local detected
  detected=$(detect_php_version)
  PHP_VER="${PHP_VER:-${detected:-8.3}}"
  mkdir -p "$PI_ROOT"
  echo "$PHP_VER" > "$PI_ROOT/php.version"
  log "Using PHP $PHP_VER"

  log "Installing PHP $PHP_VER and extensions..."
  php_modules_install || die "Failed to install PHP modules."

  log "Installing MariaDB, Redis and Nginx..."
  apt-get install -y mariadb-server mariadb-client redis-server nginx >>"$INSTALL_LOG" 2>&1 \
    || die "Failed to install database/webserver packages."

  log "Starting services..."
  ensure_service mariadb 3 || die "MariaDB failed to start."
  ensure_service redis-server 3 || die "Redis failed to start."
  ensure_service "php$PHP_VER-fpm" 3 || die "PHP-FPM failed to start."
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
  mysql -e "ALTER USER 'pelican'@'127.0.0.1' IDENTIFIED BY '$db_password';" 2>>"$INSTALL_LOG"
  mysql -e "ALTER USER 'pelican'@'localhost' IDENTIFIED BY '$db_password';" 2>>"$INSTALL_LOG"
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
  if ! grep -q '^APP_KEY=base64' "$PANEL_DIR/.env" 2>/dev/null; then
    log "APP_KEY missing after key:generate - generating manually..."
    local app_key
    app_key="base64:$(openssl rand -base64 32)"
    sed -i "s|^APP_KEY=.*|APP_KEY=$app_key|" "$PANEL_DIR/.env" 2>/dev/null \
      || echo "APP_KEY=$app_key" >> "$PANEL_DIR/.env"
  fi
  grep -q '^APP_KEY=base64' "$PANEL_DIR/.env" || die "Failed to set APP_KEY"

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
  if dpkg -s "php$(panel_php_version)-redis" >/dev/null 2>&1 || dpkg -s php-redis >/dev/null 2>&1; then
    redis_client=phpredis
  fi
  cat > "$PANEL_DIR/.env" <<EOF
APP_ENV=production
APP_ENVIRONMENT=production
APP_DEBUG=false
APP_INSTALLED=false
APP_KEY=
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
  local listen_line="listen 127.0.0.1:8443 ssl http2;"
  local h2_line=""
  if command -v nginx >/dev/null 2>&1; then
    local ngx_v
    ngx_v=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    if [ -n "$ngx_v" ] && dpkg --compare-versions "$ngx_v" ge 1.25.1 2>/dev/null; then
      listen_line="listen 127.0.0.1:8443 ssl;"
      h2_line="    http2 on;"
    fi
  fi
  cat > /etc/nginx/sites-available/pelican.conf <<EOF
server {
    $listen_line
$h2_line
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

    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_types
        application/javascript
        application/json
        application/xml
        font/woff2
        image/svg+xml
        text/css
        text/plain;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php$(panel_php_version)-fpm.sock;
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

admin_phase() {
  banner "Phase 4 - Admin account"
  local count
  count=$(mysql -N -B -e "SELECT COUNT(*) FROM pelican.users;" 2>/dev/null || echo 0)
  if [ "${count:-0}" -ge 1 ] 2>/dev/null; then
    log "Admin account already exists."
    sed -i 's/^APP_INSTALLED=.*/APP_INSTALLED=true/' "$PANEL_DIR/.env" 2>/dev/null || true
    return 0
  fi

  local admin_email admin_user admin_pass
  admin_email=${ADMIN_EMAIL:-admin@$DOMAIN}
  admin_user=${ADMIN_USERNAME:-admin}
  admin_pass=$(random_hex 12)

  log "Creating admin account ($admin_user / $admin_email)..."
  (cd "$PANEL_DIR" && php artisan p:user:make --email="$admin_email" --username="$admin_user" \
    --password="$admin_pass" --admin=1 --no-interaction) >>"$INSTALL_LOG" 2>&1 || true

  count=$(mysql -N -B -e "SELECT COUNT(*) FROM pelican.users;" 2>/dev/null || echo 0)
  if [ "${count:-0}" -ge 1 ] 2>/dev/null; then
    sed -i 's/^APP_INSTALLED=.*/APP_INSTALLED=true/' "$PANEL_DIR/.env" 2>/dev/null || true
    {
      echo "ADMIN_EMAIL=$admin_email"
      echo "ADMIN_USERNAME=$admin_user"
      echo "ADMIN_PASSWORD=$admin_pass"
    } >> "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    log "Panel installation completed via CLI."
    echo ""
    echo "  ADMIN LOGIN:"
    echo "    URL:      https://$PANEL_FQDN"
    echo "    Username: $admin_user"
    echo "    Password: $admin_pass"
    echo ""
  else
    log_err "Admin account creation failed - create it manually:"
    log_err "  cd /var/www/pelican && php artisan p:user:make --email you@example.com --username admin --admin=1"
  fi
}

egg_images_phase() {
  banner "Phase 5 - Updating eggs with modern Java images"
  log "Adding Java 21/22 docker images to Java-based eggs..."
  mysql <<SQL 2>>"$INSTALL_LOG" || true
UPDATE pelican.eggs
SET docker_images = JSON_SET(docker_images, '$."Java 21"', 'ghcr.io/pelican-eggs/yolks:java_21', '$."Java 22"', 'ghcr.io/pelican-eggs/yolks:java_22')
WHERE docker_images LIKE '%pterodactyl/yolks:java_%'
  AND JSON_UNQUOTE(JSON_EXTRACT(docker_images, '$."Java 21"')) IS NULL;
SQL
  log "Egg images updated (modern Minecraft requires Java 21+)."
}

nginx_enable_phase() {
  banner "Phase 8 - Finalizing nginx behind tunnel"
  if [ ! -f "$PANEL_TLS_DIR/panel/fullchain.pem" ]; then
    log "Panel TLS certificate not found yet - waiting for Cloudflare phase to issue it."
    return 1
  fi
  write_nginx_config
  ensure_service nginx 3 || log_err "Nginx failed to start - check /var/log/nginx/pelican.app-error.log"
}
