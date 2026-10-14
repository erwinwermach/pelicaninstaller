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
  run_heartbeat_sh "panel optimization (caches)" 900 \
    'cd "$1" && COMPOSER_ALLOW_SUPERUSER=1 php artisan optimize && COMPOSER_ALLOW_SUPERUSER=1 php artisan filament:optimize && COMPOSER_ALLOW_SUPERUSER=1 php artisan icons:cache' \
    "$PANEL_DIR" || {
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

tune_cpu_governor() {
  local mode=${TUNE_CPU_GOVERNOR:-off}
  case "$mode" in
    off|no) return 0 ;;
  esac
  local gov
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
  [ -n "$gov" ] || return 0
  if [ "$mode" != "performance" ] && [ "$gov" != "powersave" ]; then
    return 0
  fi
  cat > /etc/systemd/system/pelican-cpu-governor.service <<'EOF'
[Unit]
Description=Set CPU governor to performance (pelican game-host tuning)
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$c" ] && echo performance > "$c"; done'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now pelican-cpu-governor.service >/dev/null 2>&1 \
    || log_err "Could not enable the CPU governor service (non-fatal)."
}

tune_sysctl() {
  local mode=${TUNE_SYSCTL:-no}
  case "$mode" in
    yes|on|true) ;;
    *) return 0 ;;
  esac
  cat > /etc/sysctl.d/99-pelican-game.conf <<'EOF'
# pelicaninstaller opt-in game-host tuning
vm.max_map_count = 262144
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
net.ipv4.tcp_fastopen = 3
EOF
  if modprobe tcp_bbr >/dev/null 2>&1 || grep -q '^tcp_bbr' /proc/modules 2>/dev/null; then
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >> /etc/sysctl.d/99-pelican-game.conf
  fi
  sysctl --system >/dev/null 2>&1 || log_err "sysctl reload reported problems (non-fatal)."
}

tune_zram() {
  local mode=${TUNE_ZRAM:-off}
  case "$mode" in
    auto|yes|on) ;;
    *) return 0 ;;
  esac
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then
    return 0
  fi
  local total zram_mb
  total=$(total_ram_mb)
  if [ "$mode" = "auto" ] && [ "$total" -ge 8192 ]; then
    return 0
  fi
  zram_mb=$(( total / 4 ))
  [ "$zram_mb" -lt 512 ] && zram_mb=512
  [ "$zram_mb" -gt 4096 ] && zram_mb=4096
  cat > /etc/systemd/system/pelican-zram.service <<EOF
[Unit]
Description=zram swap for low-memory game hosting (pelican tuning)
After=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe zram || exit 0; dev=\$(zramctl --find --size ${zram_mb}M --algorithm lz4) || exit 0; mkswap "\$dev" >/dev/null && swapon -p 100 "\$dev"'
ExecStop=/bin/sh -c 'swapon -s | awk "NR>1 {print \\\$1}" | grep "^/dev/zram" | while read d; do swapoff "\$d"; done; for d in /dev/zram*; do zramctl --reset "\$d" 2>/dev/null || true; done'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now pelican-zram.service >/dev/null 2>&1 \
    || log_err "zram setup failed (kernel support missing?) - non-fatal."
}

tune_io_scheduler() {
  local mode=${TUNE_IO_SCHEDULER:-off}
  case "$mode" in
    auto|on|yes) ;;
    *) return 0 ;;
  esac
  cat > /etc/udev/rules.d/60-pelican-io-scheduler.rules <<'EOF'
# pelicaninstaller opt-in low-latency IO for game server hosts
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="vd[a-z]*", ATTR{queue/scheduler}="mq-deadline"
EOF
  udevadm control --reload-rules >/dev/null 2>&1 || true
  udevadm trigger --subsystem-match=block >/dev/null 2>&1 || true
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
  log "Applying opt-in game-host tuning (CPU governor, sysctls, zram, IO scheduler)..."
  tune_cpu_governor
  tune_sysctl
  tune_zram
  tune_io_scheduler
  log "Optimizing panel caches..."
  panel_optimize || true
}
