#!/usr/bin/env bash
set -euo pipefail

UPD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$UPD_DIR"
# shellcheck source=../lib/common.sh
. "$UPD_DIR/lib/common.sh"

exec 9>"$LOCK_DIR/pelican-update.lock"
flock -n 9 || exit 0

mkdir -p "$LOG_DIR"
INSTALL_LOG="$LOG_DIR/update.log"

log "weekly update run starting"
if installer_running; then
  log "installer is running - skipping this cycle"
  exit 0
fi
# Hold the installer lock for the whole update so heal cycles (and the
# self-update tree swap at the end) can never overlap with this run.
exec 8>"$LOCK_DIR/pelican-installer.lock"
flock -n 8 || { log "could not acquire the installer lock - skipping this cycle"; exit 0; }
wait_network 60 || { log "no network - skipping"; exit 0; }
[ -f "$CONF_FILE" ] || { log "not configured - skipping"; exit 0; }

export DEBIAN_FRONTEND=noninteractive

PANEL_MAINT=0
panel_up_now() {
  (cd "$PANEL_DIR" && php artisan up) >>"$INSTALL_LOG" 2>&1 || true
}
restore_panel_on_exit() {
  [ "${PANEL_MAINT:-0}" = "1" ] && panel_up_now
  return 0
}
trap restore_panel_on_exit EXIT

log "Updating Ubuntu packages..."
run_with_heartbeat "apt-get update" 600 \
  apt-get -y -o DPkg::Lock::Timeout=300 update || true
run_with_heartbeat "apt-get full-upgrade" 10800 \
  apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade || true
dpkg --configure -a >>"$INSTALL_LOG" 2>&1 || true
run_with_heartbeat "apt-get autoremove" 1200 \
  apt-get -y -o DPkg::Lock::Timeout=300 autoremove --purge || true
apt-get clean >>"$INSTALL_LOG" 2>&1 || true

if [ -f "$PANEL_DIR/artisan" ] && [ -f "$PANEL_DIR/.env" ] && grep -q '^APP_INSTALLED=true' "$PANEL_DIR/.env"; then
  log "Updating Pelican Panel..."
  if (cd "$PANEL_DIR" && php artisan down --retry=30) >>"$INSTALL_LOG" 2>&1; then
    PANEL_MAINT=1
  fi
  panel_tar=$(mktemp /tmp/panel-update.XXXXXX.tar.gz)
  if run_with_heartbeat "Panel download" 600 \
       curl -fsSL -m 300 -o "$panel_tar" \
       "https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz" \
     && [ "$(stat -c %s "$panel_tar" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    run_with_heartbeat "Panel extraction" 600 tar -xzf "$panel_tar" -C "$PANEL_DIR" \
      || log_err "Panel tarball extraction reported errors."
    # shellcheck source=../lib/panel.sh
    . "$UPD_DIR/lib/panel.sh"
    req_php=$(panel_php_requirement)
    cur_php=$(panel_php_version)
    if [ -n "$req_php" ] && ! php_version_satisfies "$cur_php" "$req_php"; then
      log_err "New panel requires PHP $req_php but this server runs $cur_php - upgrading PHP..."
      ensure_php_ppa || log_err "Could not enable the ondrej/php PPA - the panel may not run."
      new_php=$(detect_php_version)
      if [ -n "$new_php" ] && [ "$new_php" != "$cur_php" ]; then
        if PHP_VER="$new_php" php_modules_install && dpkg -s "php$new_php-fpm" >/dev/null 2>&1; then
          echo "$new_php" > "$PI_ROOT/php.version"
          # shellcheck source=../lib/tune.sh
          . "$UPD_DIR/lib/tune.sh"
          tune_php_fpm || true
          log "PHP upgraded from $cur_php to $new_php."
        else
          log_err "PHP $new_php modules could not be installed - the panel may not run until this is fixed."
        fi
      fi
    fi
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" || log_err "Could not fix panel storage permissions."
    run_heartbeat_sh "composer install" 2400 \
      'cd "$1" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction' \
      "$PANEL_DIR" || log_err "composer install failed - panel may be incomplete."
    (cd "$PANEL_DIR" && php artisan storage:link) >>"$INSTALL_LOG" 2>&1 || true
    # shellcheck source=../lib/tune.sh
    . "$UPD_DIR/lib/tune.sh"
    panel_optimize || true
    run_heartbeat_sh "panel database migration" 1800 \
      'cd "$1" && php artisan migrate --seed --force' "$PANEL_DIR" \
      || log_err "Panel migrations failed - check the panel logs."
    (cd "$PANEL_DIR" && php artisan queue:restart) >>"$INSTALL_LOG" 2>&1 || true
    chown -R www-data:www-data "$PANEL_DIR" || log_err "Could not reset panel ownership."
    (cd "$PANEL_DIR" && php artisan up) >>"$INSTALL_LOG" 2>&1 || true
    PANEL_MAINT=0
    restart_service "php$(panel_php_version)-fpm"
    restart_service nginx
    log "Panel updated."
  else
    log_err "Panel update download failed or was truncated - keeping the current panel."
  fi
  rm -f "$panel_tar"

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
  plugins_update_all 2>/dev/null || true
  plugins_patch_modpack 2>/dev/null || true
  plugins_sync_curseforge_key 2>/dev/null || true
  plugins_verify_curseforge_key 2>/dev/null || true
else
  log "Panel not installed yet - skipping panel update."
fi

if [ -f "$PELICAN_ETC/config.yml" ]; then
  log "Updating Wings..."
  wings_tmp=$(mktemp /tmp/wings-new.XXXXXX)
  if run_with_heartbeat "Wings download" 600 \
       curl -fsSL -m 300 -o "$wings_tmp" \
       "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_$(arch_map)" \
     && [ "$(stat -c %s "$wings_tmp" 2>/dev/null || echo 0)" -gt 5000000 ]; then
    chmod +x "$wings_tmp"
    if ! cmp -s "$wings_tmp" "$WINGS_BIN"; then
      mv -f "$wings_tmp" "$WINGS_BIN"
      restart_service wings
      log "Wings updated."
    else
      rm -f "$wings_tmp"
    fi
  else
    log_err "Wings download failed or was truncated - keeping the current binary."
    rm -f "$wings_tmp"
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
run_with_heartbeat "docker image prune" 600 docker image prune -f || true

log "Refreshing installer scripts from GitHub..."
self_update
if [ "${PI_UPDATE_PERFORMED:-0}" = "1" ]; then
  log "Installer scripts updated to version $(pi_local_version)."
else
  log "Installer scripts are up to date (version $(pi_local_version))."
fi
deploy_heal_units "$PI_HOME/systemd"

log "weekly update complete"
exit 0
