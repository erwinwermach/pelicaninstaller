total_ram_mb() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

php_fpm_max_children() {
  local ram
  ram=$(total_ram_mb)
  local n=$(( ram * 20 / 100 / 64 ))
  [ "$n" -lt 4 ] && n=4
  [ "$n" -gt 24 ] && n=24
  echo "$n"
}

innodb_pool_size() {
  local ram pool
  ram=$(total_ram_mb)
  pool=$(( ram * 25 / 100 ))
  [ "$pool" -gt 512 ] && pool=512
  [ "$pool" -lt 128 ] && pool=128
  echo "${pool}M"
}

tune_php_fpm() {
  local php_ver
  php_ver=$(panel_php_version)
  local children
  children=$(php_fpm_max_children)
  cat > "/etc/php/$php_ver/fpm/pool.d/zz-pelican.conf" <<EOF
[www]
pm = ondemand
pm.max_children = $children
pm.process_idle_timeout = 20s
pm.max_requests = 500
pm.status_path = /fpm-status
request_terminate_timeout = 300s
EOF

  cat > "/etc/php/$php_ver/fpm/conf.d/90-pelican.ini" <<'EOF'
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
opcache.save_comments = 1
opcache.jit = off
realpath_cache_size = 4096K
realpath_cache_ttl = 600
memory_limit = 512M
max_execution_time = 120
EOF

  cat > "/etc/php/$php_ver/cli/conf.d/90-pelican-cli.ini" <<'EOF'
memory_limit = -1
EOF

  restart_service "php$php_ver-fpm"
}

tune_mariadb() {
  cat > /etc/mysql/mariadb.conf.d/99-pelican.cnf <<EOF
[mysqld]
skip-name-resolve = 1
innodb_buffer_pool_size = $(innodb_pool_size)
innodb_flush_method = O_DIRECT
max_connections = 150
tmp_table_size = 32M
max_heap_table_size = 32M
table_open_cache = 800
EOF
  restart_service mariadb
}

tune_redis() {
  local conf=/etc/redis/redis.conf
  [ -f "$conf" ] || return 0
  if grep -qE '^maxmemory ' "$conf"; then
    sed -i 's/^maxmemory .*/maxmemory 512mb/' "$conf"
  else
    printf '\nmaxmemory 512mb\n' >> "$conf"
  fi
  if grep -qE '^maxmemory-policy ' "$conf"; then
    sed -i 's/^maxmemory-policy .*/maxmemory-policy noeviction/' "$conf"
  else
    printf 'maxmemory-policy noeviction\n' >> "$conf"
  fi
  restart_service redis-server
}

tune_nginx() {
  cat > /etc/nginx/conf.d/pelican-tuning.conf <<'EOF'
open_file_cache max=2000 inactive=30s;
open_file_cache_valid 60s;
open_file_cache_min_uses 2;
open_file_cache_errors on;
EOF
}

ufw_port_tokens() {
  local spec=${1:-} token out=""
  [ -n "$spec" ] || spec="25565-25575"
  for token in ${spec//,/ }; do
    out="$out ${token/-/:}"
  done
  echo "$out"
}

panel_optimize() {
  [ -f "$PANEL_DIR/artisan" ] || return 0
  (
    cd "$PANEL_DIR" && \
    COMPOSER_ALLOW_SUPERUSER=1 php artisan optimize && \
    COMPOSER_ALLOW_SUPERUSER=1 php artisan filament:optimize && \
    COMPOSER_ALLOW_SUPERUSER=1 php artisan icons:cache
  ) >>"$INSTALL_LOG" 2>&1 || {
    log_err "Panel optimization step failed (non-fatal)."
    return 1
  }
  chown -R www-data:www-data "$PANEL_DIR/bootstrap/cache" "$PANEL_DIR/storage/framework" 2>/dev/null || true
  restart_service pelican-queue 2>/dev/null || true
  return 0
}

add_static_caching() {
  local conf=/etc/nginx/sites-available/pelican.conf
  [ -f "$conf" ] || return 0
  grep -qE 'location ~\* \^/\(js\|css\|vendor\|fonts\)/' "$conf" && return 0
  local tmp
  tmp=$(mktemp)
  awk '
    /location \/ \{/ && !inserted {
      print "    location ~* ^/(js|css|vendor|fonts)/ {";
      print "        expires 7d;";
      print "        add_header Cache-Control \"public, immutable\";";
      print "        access_log off;";
      print "        try_files $uri =404;";
      print "    }";
      print "";
      inserted = 1;
    }
    { print }
  ' "$conf" > "$tmp"
  mv -f "$tmp" "$conf"
  restart_service nginx
}

tune_phase() {
  banner "Phase 9 - Low-end hardware tuning"
  log "Applying PHP-FPM/opcache tuning..."
  tune_php_fpm
  log "Applying MariaDB tuning..."
  tune_mariadb
  log "Applying Redis memory cap..."
  tune_redis
  log "Applying nginx gzip/caching tuning..."
  tune_nginx
  add_static_caching
  log "Optimizing panel caches..."
  panel_optimize || true
}
