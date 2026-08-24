WIPE_SERVICES="docker containerd docker.socket nginx apache2 caddy mysql mariadb redis-server cloudflared wings php8.1-fpm php8.2-fpm php8.3-fpm php8.4-fpm php8.5-fpm php-fpm frpc bore@25565"

wipe_phase() {
  banner "Phase 1 - Clean slate wipe"
  log "Stopping all conflicting services..."
  local svc
  for svc in $WIPE_SERVICES; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
  systemctl list-unit-files 'bore@*.service' 2>/dev/null | awk '/^bore@/ {print $1}' | while read -r u; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
  done

  log "Purging conflicting packages..."
  local purge_list
  purge_list=$(dpkg -l 2>/dev/null | awk '/^ii / {print $2}' | grep -E '^(docker|containerd|nginx|apache2|caddy|mysql|mariadb|redis|php[0-9]|php-|php$|cloudflared|certbot|acme)' || true)
  if [ -n "$purge_list" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y --allow-change-held-packages $purge_list >/dev/null 2>&1 || true
  fi

  log "Removing leftover data and config directories..."
  rm -rf /var/www/pelican /var/www/pterodactyl \
    /etc/pelican /etc/cloudflared /etc/nginx /etc/apache2 /etc/php /etc/mysql \
    /var/lib/mysql /var/lib/mariadb /var/lib/docker /var/lib/redis /var/cache/nginx \
    /var/log/nginx /etc/letsencrypt /root/.acme.sh \
    /var/lib/pelican /var/run/wings \
    /usr/local/bin/bore /usr/local/bin/frpc /opt/frp /etc/frps.toml \
    /etc/systemd/system/frpc.service /etc/systemd/system/frps.service \
    /etc/systemd/system/bore@.service /etc/docker/daemon.json
  systemctl daemon-reload 2>/dev/null || true

  log "Repairing and cleaning apt..."
  DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
  log "Clean slate ready."
}
