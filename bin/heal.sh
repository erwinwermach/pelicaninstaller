#!/usr/bin/env bash
set -u

HEAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HEAL_DIR/lib/common.sh"

exec 9>"$LOCK_DIR/pelican-heal.lock"
flock -n 9 || exit 0

mkdir -p "$LOG_DIR"
INSTALL_LOG="$LOG_DIR/heal.log"

hlog() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$INSTALL_LOG"
}

hlog "heal run starting"

wait_network 120 || { hlog "no network - retrying next cycle"; exit 0; }

if [ ! -f "$CONF_FILE" ]; then
  hlog "not configured yet - skipping"
  exit 0
fi

PANEL_SUBDOMAIN=${PANEL_SUBDOMAIN:-panel}
NODE_SUBDOMAIN=${NODE_SUBDOMAIN:-node}
if [ -z "${DOMAIN:-}" ]; then
  hlog "config has no DOMAIN - skipping"
  exit 0
fi

PANEL_FQDN="$PANEL_SUBDOMAIN.$DOMAIN"
NODE_FQDN="$NODE_SUBDOMAIN.$DOMAIN"
PHP_FPM="php$(panel_php_version)-fpm"

core_services() {
  local svc
  if command -v mariadb-install-db >/dev/null 2>&1 && id mysql >/dev/null 2>&1; then
    chage -E -1 -m 0 -M 99999 -I -1 mysql >/dev/null 2>&1 || true
    usermod -U mysql >/dev/null 2>&1 || true
    local dd
    dd=""
    if command -v mariadbd >/dev/null 2>&1; then
      dd=$(mariadbd --print-defaults 2>/dev/null | tr ' ' '\n' | grep -E '^--datadir=' | head -1 | cut -d= -f2-)
    fi
    if [ -z "$dd" ]; then
      dd=$(grep -rhE '^\s*datadir\s*=' /etc/mysql/ 2>/dev/null | head -1 | sed -E 's/^.*datadir\s*=\s*//' | tr -d ' #')
    fi
    if [ -z "$dd" ]; then
      if command -v mariadbd >/dev/null 2>&1; then
        dd=$(mariadbd --help --verbose 2>/dev/null | awk '/^datadir/ {print $2; exit}' | sed 's:/*$::')
      fi
    fi
    if [ -z "$dd" ]; then
      if [ -d /var/lib/mariadb/mysql ] && [ ! -d /var/lib/mysql/mysql ]; then
        dd=/var/lib/mariadb
      elif [ -d /var/lib/mysql/mysql ] && [ ! -d /var/lib/mariadb/mysql ]; then
        dd=/var/lib/mysql
      elif dpkg -l mariadb-server 2>/dev/null | grep -q '11\.8\.6-5'; then
        dd=/var/lib/mariadb
      else
        dd=/var/lib/mysql
      fi
    fi
    if [ ! -d "$dd/mysql" ]; then
      hlog "mariadb datadir $dd missing system schema - re-initializing as mysql user"
      systemctl stop mariadb >/dev/null 2>&1 || true
      mkdir -p "$dd"
      rm -rf "$dd"/*
      chown mysql:mysql "$dd"
      chmod 750 "$dd"
      su -s /bin/bash mysql -c "mariadb-install-db --datadir='$dd' --user=mysql" >/dev/null 2>&1 \
        && hlog "mariadb datadir re-initialized" \
        || hlog "mariadb datadir re-init failed"
    fi
  fi
  for svc in mariadb redis-server "$PHP_FPM" nginx docker; do
    if ! ensure_service "$svc" 2; then
      hlog "FAILED to bring up $svc"
    fi
  done
}

core_services

if [ -n "${CF_API_TOKEN:-}" ]; then
  # shellcheck source=../lib/cloudflare.sh
  . "$HEAL_DIR/lib/cloudflare.sh"
  if cf_deep_due; then
    if ! cf_full_ensure > /dev/null 2>&1; then
      hlog "cloudflare deep ensure reported problems (see $LOG_DIR/heal.log)"
    fi
    cf_deep_mark
  else
    if ! cf_light_ensure > /dev/null 2>&1; then
      hlog "cloudflare light ensure failed - escalating to full check"
      cf_full_ensure > /dev/null 2>&1 || hlog "cloudflare full ensure failed too"
      cf_deep_mark
    fi
  fi
else
  if [ -f "$CF_CFG_FILE" ] && [ -x "$CF_BIN" ]; then
    ensure_service cloudflared 2 > /dev/null 2>&1 || hlog "FAILED to bring up cloudflared"
  fi
fi

if ! curl -k -sS -m 10 -o /dev/null https://127.0.0.1:8443/ 2>/dev/null; then
  hlog "panel unreachable - restarting nginx and php-fpm"
  restart_service "$PHP_FPM"
  restart_service nginx
  sleep 3
  curl -k -sS -m 10 -o /dev/null https://127.0.0.1:8443/ 2>/dev/null || hlog "panel still unreachable"
fi

if [ -f "$PELICAN_ETC/config.yml" ]; then
  if ! curl -sS -m 10 -o /dev/null http://127.0.0.1:8080/api/system 2>/dev/null; then
    hlog "wings API unreachable - restarting wings"
    restart_service wings
  fi
fi

# shellcheck source=../lib/node.sh
. "$HEAL_DIR/lib/node.sh"
ensure_node

# Reconcile admin permissions + extra eggs (idempotent, throttled to once/hour)
if [ ! -f "$PI_ROOT/.panel-reconciled" ] || [ $(($(date +%s) - $(stat -c %Y "$PI_ROOT/.panel-reconciled" 2>/dev/null || echo 0))) -gt 3600 ]; then
  if panel_admin_exists && [ -f "$PANEL_DIR/.env" ] && grep -q '^APP_INSTALLED=true' "$PANEL_DIR/.env"; then
    PHP_BIN="php$(panel_php_version)"
    (cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 "$PHP_BIN" artisan tinker --execute="
use Spatie\Permission\Models\Permission;
\$role = \App\Models\Role::getRootAdmin();
\$perms = [];
foreach (\App\Models\Role::getPermissionList() as \$model => \$prefixes) {
    foreach (\$prefixes as \$prefix) {
        \$perms[] = Permission::findOrCreate(\$prefix . ' ' . \$model, 'web')->name;
    }
}
\$role->syncPermissions(\$perms);
" >/dev/null 2>&1) || true
    # shellcheck source=../lib/panel.sh
    . "$HEAL_DIR/lib/panel.sh"
    panel_patch_navigation >>"$INSTALL_LOG" 2>&1 || true
    # shellcheck source=../lib/eggs.sh
    . "$HEAL_DIR/lib/eggs.sh"
    ensure_app_api_key >/dev/null 2>&1 && eggs_phase >/dev/null 2>&1 || true
    touch "$PI_ROOT/.panel-reconciled" 2>/dev/null || true
  fi
fi

# shellcheck source=../lib/routing.sh
. "$HEAL_DIR/lib/routing.sh"
if [ "$GAME_ROUTING" != "none" ]; then
  if [ ! -f "$PI_ROOT/.routing-synced" ] || [ $(($(date +%s) - $(stat -c %Y "$PI_ROOT/.routing-synced" 2>/dev/null || echo 0))) -gt 600 ]; then
    case "$GAME_ROUTING" in
      playit)
        if [ -n "${PLAYIT_SECRET_KEY:-}" ] || [ -n "$(panel_env_get PLAYIT_SECRET_KEY)" ]; then
          playit_agent_ensure >>"$INSTALL_LOG" 2>&1 || true
        fi
        if [ -f "$NODE_ATTEMPT_FILE" ] && [ -f "$PELICAN_ETC/config.yml" ]; then
          playit_create_tunnels > /dev/null 2>&1 || true
        fi
        ;;
    esac
    routing_sync >>"$INSTALL_LOG" 2>&1 || hlog "routing sync failed"
    touch "$PI_ROOT/.routing-synced" 2>/dev/null || true
  fi
fi

# shellcheck source=../lib/jarfix.sh
. "$HEAL_DIR/lib/jarfix.sh"
process_repair_requests
server_jars_fix
server_permissions_fix

# shellcheck source=../lib/perfctl.sh
. "$HEAL_DIR/lib/perfctl.sh"
perf_scan
perfctl_process_requests

# shellcheck source=../lib/crashscan.sh
. "$HEAL_DIR/lib/crashscan.sh"
crash_scan

write_health_json() {
  local disk_used
  disk_used=$(df -Pk / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  mkdir -p /var/www/pelican/storage/app
  {
    echo "{"
    echo "  \"last_heal\": \"$(date -Is)\","
    echo "  \"disk_used\": ${disk_used:-0},"
    echo "  \"game_routing\": \"$GAME_ROUTING\","
    echo "  \"services\": {"
    first=1
    for s in mariadb redis-server "$PHP_FPM" nginx docker cloudflared wings pelican-queue; do
      if [ "$first" -ne 1 ]; then echo ","; fi
      first=0
      st=$(systemctl is-active "$s" 2>/dev/null || true)
      [ -n "$st" ] || st=unknown
      printf '    "%s": "%s"' "$s" "$st"
    done
    for extra in frpc; do
      systemctl list-unit-files "${extra}.service" >/dev/null 2>&1 || continue
      if [ "$first" -ne 1 ]; then echo ","; fi
      first=0
      st=$(systemctl is-active "$extra" 2>/dev/null || true)
      [ -n "$st" ] || st=unknown
      printf '    "%s": "%s"' "$extra" "$st"
    done
    if [ "$first" -ne 1 ]; then echo ","; fi
    st=inactive
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx playit-agent && st=active
    printf '    "playit-agent": "%s"' "$st"
    echo ""
    echo "  }"
    echo "}"
  } > /var/www/pelican/storage/app/pelican-health.json 2>/dev/null || true
  chown www-data:www-data /var/www/pelican/storage/app/pelican-health.json 2>/dev/null || true
}

write_health_json

hlog "heal run complete"
exit 0
