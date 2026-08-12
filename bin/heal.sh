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

PANEL_FQDN="$PANEL_SUBDOMAIN.$DOMAIN"
NODE_FQDN="$NODE_SUBDOMAIN.$DOMAIN"

core_services() {
  local svc
  for svc in mariadb redis-server php8.3-fpm nginx docker; do
    if ! ensure_service "$svc" 2; then
      hlog "FAILED to bring up $svc"
    fi
  done
}

core_services

if [ -n "${CF_API_TOKEN:-}" ]; then
  # shellcheck source=../lib/cloudflare.sh
  . "$HEAL_DIR/lib/cloudflare.sh"
  if ! cf_full_ensure > /dev/null 2>&1; then
    hlog "cloudflare ensure reported problems (see $LOG_DIR/heal.log)"
  fi
else
  if [ -f "$CF_CFG_FILE" ] && [ -x "$CF_BIN" ]; then
    ensure_service cloudflared 2 > /dev/null 2>&1 || hlog "FAILED to bring up cloudflared"
  fi
fi

if ! curl -k -sS -m 10 -o /dev/null https://127.0.0.1:8443/ 2>/dev/null; then
  hlog "panel unreachable - restarting nginx and php-fpm"
  restart_service php8.3-fpm
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

# shellcheck source=../lib/playit.sh
. "$HEAL_DIR/lib/playit.sh"
if [ -f "$NODE_ATTEMPT_FILE" ] && [ -f "$PELICAN_ETC/config.yml" ]; then
  if [ ! -f "$PI_ROOT/.playit-synced" ] || [ $(($(date +%s) - $(stat -c %Y "$PI_ROOT/.playit-synced" 2>/dev/null || echo 0))) -gt 600 ]; then
    playit_ensure_tunnels
    touch "$PI_ROOT/.playit-synced" 2>/dev/null || true
  fi
fi

# shellcheck source=../lib/jarfix.sh
. "$HEAL_DIR/lib/jarfix.sh"
server_jars_fix

disk_used=$(df -Pk / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
if [ "${disk_used:-0}" -gt 85 ]; then
  hlog "WARNING: disk usage at ${disk_used}%"
fi

hlog "heal run complete"
exit 0
