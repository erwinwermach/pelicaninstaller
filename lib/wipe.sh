WIPE_SERVICES="docker containerd docker.socket nginx apache2 caddy mysql mariadb redis-server cloudflared wings php8.1-fpm php8.2-fpm php8.3-fpm php8.4-fpm php8.5-fpm php-fpm frpc bore@25565"

wipe_phase() {
  banner "Phase 1 - Clean slate wipe (keeps OS, SSH, user data)"
  local failures=0

  log "Backing up installer config/secrets to /var/backups/pelican-installer..."
  mkdir -p /var/backups/pelican-installer 2>/dev/null || true
  if [ -d "$PI_ROOT" ] && ! tar -czf "/var/backups/pelican-installer/state-$(date +%Y%m%d-%H%M%S).tar.gz" \
      -C "$(dirname "$PI_ROOT")" "$(basename "$PI_ROOT")" 2>/dev/null; then
    log_err "Could not back up $PI_ROOT - aborting the wipe so your config/secrets are not lost."
    return 1
  fi

  log "Stopping all conflicting services..."
  local svc
  for svc in $WIPE_SERVICES; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
  while read -r u; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
  done < <(systemctl list-unit-files 'bore@*.service' 2>/dev/null | awk '/^bore@/ {print $1}') || true

  log "Purging conflicting packages..."
  local purge_list
  purge_list=$(dpkg -l 2>/dev/null | awk '/^ii / {print $2}' \
    | grep -E '^(docker\.io|docker-ce|docker-ce-cli|containerd|containerd\.io|nginx|nginx-common|nginx-core|apache2|caddy|mysql-server|mysql-client|mysql-common|mariadb-server|mariadb-client|mariadb-common|redis-server|redis-tools|cloudflared|php|php-.*|php8\.[0-9]+|php8\.[0-9]+-.*|frpc)$' || true)
  if [ -n "$purge_list" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y --allow-change-held-packages $purge_list >/dev/null 2>&1 || {
      log_err "apt purge failed for some packages - continuing with directory cleanup."
      failures=$((failures + 1))
    }
  fi

  log "Removing leftover data and config directories..."
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$(docker ps -aq 2>/dev/null)" >/dev/null 2>&1 || true
    docker system prune -af >/dev/null 2>&1 || true
  fi
  for m in $(mount 2>/dev/null | awk '/\/var\/lib\/docker/ {print $3}'); do
    umount -lf "$m" >/dev/null 2>&1 || true
  done
  rm -rf /var/www/pelican /var/www/pterodactyl \
    /etc/pelican /etc/cloudflared /etc/nginx /etc/apache2 /etc/php /etc/mysql \
    /var/lib/mysql /var/lib/mariadb /var/lib/docker /var/lib/redis /var/cache/nginx \
    /var/log/nginx \
    /var/lib/pelican /var/run/wings \
    /usr/local/bin/bore /usr/local/bin/frpc /opt/frp /etc/frps.toml \
    /etc/systemd/system/frpc.service /etc/systemd/system/frps.service \
    /etc/systemd/system/bore@.service /etc/docker/daemon.json || {
    log_err "Some installer directories could not be removed."
    failures=$((failures + 1))
  }
  systemctl daemon-reload 2>/dev/null || true

  log "Repairing and cleaning apt..."
  DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true

  if [ "$failures" -ne 0 ]; then
    log_err "Clean-slate wipe finished with $failures failure(s) - installer state was NOT deleted."
    return 1
  fi
  log "Clean slate ready."
  return 0
}
