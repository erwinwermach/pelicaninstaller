#!/usr/bin/env bash
set -euo pipefail

# Force-refresh the managed stack from the command line (SSH friendly):
#   sudo /opt/pelican-installer/bin/refresh.sh                # everything below
#   sudo /opt/pelican-installer/bin/refresh.sh plugins key    # selected parts
#   sudo /opt/pelican-installer/bin/refresh.sh system         # full weekly update now
#
# Components: scripts services routing plugins key eggs panel|caches system
# `all` (the default) runs everything except `system` (the heavy apt/panel/wings
# update, which is update.sh and takes a long time on purpose).

REFRESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REFRESH_DIR"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

need_root

mkdir -p "$LOG_DIR" "$LOCK_DIR"
INSTALL_LOG="$LOG_DIR/refresh.log"
export INSTALL_LOG

targets="${*:-all}"

log "refresh starting (targets: $targets)"

if [ ! -f "$CONF_FILE" ]; then
  die "No configuration at $CONF_FILE - run the installer first."
fi

if installer_running; then
  log "installer is running - try again when it finished"
  exit 0
fi
exec 8>"$LOCK_DIR/pelican-installer.lock"
flock -n 8 || { log "another installer/update is running - try again later"; exit 0; }

# Re-load the config values (common.sh already sanitized/sourced it, but
# refresh.sh may run long after the tree changed).
set -a
# shellcheck disable=SC1090
. "$CONF_FILE"
set +a

PANEL_SUBDOMAIN=${PANEL_SUBDOMAIN:-panel}
NODE_SUBDOMAIN=${NODE_SUBDOMAIN:-node}
PANEL_FQDN="$PANEL_SUBDOMAIN.$DOMAIN"
NODE_FQDN="$NODE_SUBDOMAIN.$DOMAIN"
PHP_FPM="php$(panel_php_version)-fpm"

want() {
  # true when $1 was requested, or when `all` was requested (except `system`)
  local t
  for t in $targets; do
    [ "$t" = "$1" ] && return 0
    if [ "$t" = "all" ] && [ "$1" != "system" ]; then
      return 0
    fi
  done
  return 1
}

failures=0
run_step() {
  local name=$1
  shift
  log "refresh: $name..."
  if "$@"; then
    return 0
  fi
  log_err "refresh: $name reported problems - see $INSTALL_LOG"
  failures=$((failures + 1))
  return 0
}

if want system; then
  log "refresh: full update via update.sh (apt, panel, wings) - this can take a while"
  # update.sh checks the same lock; release our fd first or it would skip.
  exec 8>&-
  exec bash "$SCRIPT_DIR/bin/update.sh"
fi

# --- installer scripts + units ---------------------------------------------
if want scripts; then
  run_step "installer scripts (self-update)" self_update
  run_step "systemd units" deploy_heal_units "$PI_HOME/systemd"
fi

# --- core services ----------------------------------------------------------
if want services; then
  for svc in mariadb redis-server "$PHP_FPM" nginx docker cloudflared wings; do
    run_step "service: $svc" ensure_service "$svc" 4
  done
  if systemctl cat pelican-queue.service >/dev/null 2>&1; then
    run_step "service: pelican-queue" ensure_service pelican-queue 4
  fi
fi

# --- cloudflare tunnel + game routing addresses -----------------------------
if want routing; then
  # shellcheck source=../lib/cloudflare.sh
  . "$SCRIPT_DIR/lib/cloudflare.sh"
  run_step "cloudflare reconcile (deep)" cf_full_ensure
  # shellcheck source=../lib/routing.sh
  . "$SCRIPT_DIR/lib/routing.sh"
  run_step "playit agent + tunnels" playit_deploy
  run_step "routing addresses" routing_sync
fi

# --- panel plugins ----------------------------------------------------------
if want plugins; then
  # shellcheck source=../lib/node.sh
  . "$SCRIPT_DIR/lib/node.sh"
  # shellcheck source=../lib/plugins.sh
  . "$SCRIPT_DIR/lib/plugins.sh"
  run_step "panel API key" ensure_app_api_key
  run_step "plugin imports (missing)" plugins_ensure_installed
  run_step "plugin updates" plugins_update_all
  run_step "plugin re-enable" plugins_reconcile
  run_step "plugin fallback patches" plugins_patch_modpack
fi

# --- CurseForge key ---------------------------------------------------------
if want key || want plugins; then
  # shellcheck source=../lib/node.sh
  . "$SCRIPT_DIR/lib/node.sh"
  # shellcheck source=../lib/plugins.sh
  . "$SCRIPT_DIR/lib/plugins.sh"
  run_step "CurseForge key sync" plugins_sync_curseforge_key
  run_step "CurseForge key verify" plugins_verify_curseforge_key
fi

# --- eggs -------------------------------------------------------------------
if want eggs; then
  # shellcheck source=../lib/node.sh
  . "$SCRIPT_DIR/lib/node.sh"
  # shellcheck source=../lib/eggs.sh
  . "$SCRIPT_DIR/lib/eggs.sh"
  run_step "egg imports ($EXTRA_EGGS)" eggs_phase
fi

# --- panel caches + queue ---------------------------------------------------
if want panel || want caches; then
  # shellcheck source=../lib/tune.sh
  . "$SCRIPT_DIR/lib/tune.sh"
  run_step "panel caches (optimize)" panel_optimize
  if [ -f "$PANEL_DIR/artisan" ]; then
    run_step "queue worker recycle" bash -c 'cd "$1" && COMPOSER_ALLOW_SUPERUSER=1 php artisan queue:restart' _ "$PANEL_DIR"
  fi
  run_step "php-fpm restart" restart_service "$PHP_FPM"
fi

if [ "$failures" -eq 0 ]; then
  log "refresh complete (no problems reported)"
else
  log_err "refresh complete with $failures problem(s) - check $INSTALL_LOG"
fi
exit 0
