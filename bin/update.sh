#!/usr/bin/env bash
set -euo pipefail

UPD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$UPD_DIR/lib/common.sh"

exec 9>"$LOCK_DIR/pelican-update.lock"
flock -n 9 || exit 0

mkdir -p "$LOG_DIR"
INSTALL_LOG="$LOG_DIR/update.log"

log "weekly update run starting"
wait_network 60 || { log "no network - skipping"; exit 0; }
[ -f "$CONF_FILE" ] || { log "not configured - skipping"; exit 0; }

export DEBIAN_FRONTEND=noninteractive

log "Updating Ubuntu packages..."
apt-get update -y >>"$INSTALL_LOG" 2>&1 || true
apt-get full-upgrade -y >>"$INSTALL_LOG" 2>&1 || true
apt-get autoremove --purge -y >>"$INSTALL_LOG" 2>&1 || true
apt-get clean >>"$INSTALL_LOG" 2>&1 || true

if [ -f "$PANEL_DIR/artisan" ] && [ -f "$PANEL_DIR/.env" ] && grep -q '^APP_INSTALLED=true' "$PANEL_DIR/.env"; then
  log "Updating Pelican Panel..."
  (cd "$PANEL_DIR" && php artisan down --retry=30) >>"$INSTALL_LOG" 2>&1 || true
  curl -fsSL -m 120 -o /tmp/panel-update.tar.gz \
    "https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz" >>"$INSTALL_LOG" 2>&1 || true
  if [ -s /tmp/panel-update.tar.gz ]; then
    tar -xzf /tmp/panel-update.tar.gz -C "$PANEL_DIR" >>"$INSTALL_LOG" 2>&1 || true
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
    (cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction) >>"$INSTALL_LOG" 2>&1 || true
    (cd "$PANEL_DIR" && php artisan storage:link) >>"$INSTALL_LOG" 2>&1 || true
    # shellcheck source=../lib/tune.sh
    . "$UPD_DIR/lib/tune.sh"
    panel_optimize || true
    (cd "$PANEL_DIR" && php artisan migrate --seed --force) >>"$INSTALL_LOG" 2>&1 || true
    (cd "$PANEL_DIR" && php artisan queue:restart) >>"$INSTALL_LOG" 2>&1 || true
    chown -R www-data:www-data "$PANEL_DIR"
    (cd "$PANEL_DIR" && php artisan up) >>"$INSTALL_LOG" 2>&1 || true
    restart_service "php$(panel_php_version)-fpm"
    restart_service nginx
    log "Panel updated."
  fi

  log "Reconciling nginx vhost + static caching after update..."
  # shellcheck source=../lib/panel.sh
  . "$UPD_DIR/lib/panel.sh"
  # shellcheck source=../lib/tune.sh
  . "$UPD_DIR/lib/tune.sh"
  PANEL_SUBDOMAIN=${PANEL_SUBDOMAIN:-panel} NODE_SUBDOMAIN=${NODE_SUBDOMAIN:-node} \
    DOMAIN=${DOMAIN:-} write_nginx_config 2>/dev/null || true
  add_static_caching 2>/dev/null || true
  panel_patch_navigation 2>/dev/null || true

  log "Reconciling extra eggs (idempotent import)..."
  # shellcheck source=../lib/node.sh
  . "$UPD_DIR/lib/node.sh"
  # shellcheck source=../lib/eggs.sh
  . "$UPD_DIR/lib/eggs.sh"
  ensure_app_api_key >/dev/null 2>&1 && eggs_phase >/dev/null 2>&1 || true
  # shellcheck source=../lib/plugins.sh
  . "$UPD_DIR/lib/plugins.sh"
  plugins_patch_modpack 2>/dev/null || true
else
  log "Panel not installed yet - skipping panel update."
fi

if [ -f "$PELICAN_ETC/config.yml" ]; then
  log "Updating Wings..."
  curl -fsSL -m 120 -o /tmp/wings-new \
    "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_$(arch_map)" >>"$INSTALL_LOG" 2>&1 || true
  if [ -s /tmp/wings-new ]; then
    if ! cmp -s /tmp/wings-new "$WINGS_BIN"; then
      chmod +x /tmp/wings-new
      mv /tmp/wings-new "$WINGS_BIN"
      restart_service wings
      log "Wings updated."
    else
      rm -f /tmp/wings-new
    fi
  fi
fi

if [ -x "$CF_BIN" ] && [ -n "${CF_API_TOKEN:-}" ]; then
  log "Refreshing Cloudflare tunnel state and certificates..."
  # shellcheck source=../lib/cloudflare.sh
  . "$UPD_DIR/lib/cloudflare.sh"
  # shellcheck source=../lib/routing.sh
  . "$UPD_DIR/lib/routing.sh"
  cf_install_binary
  cf_ensure_certs || true
  cf_ensure_dns || true
  cf_write_config || true
  routing_sync || true
fi

log "Pruning dangling docker images..."
docker image prune -f >>"$INSTALL_LOG" 2>&1 || true

log "Refreshing installer scripts from GitHub..."
if self_update; then
  log "Installer scripts are up to date (version $(pi_local_version))."
else
  log "Installer scripts updated to version $(pi_local_version)."
fi

log "weekly update complete"
exit 0
