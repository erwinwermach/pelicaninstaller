#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SKIP_WIPE=0
AUTO_REBOOT_FLAG=""
FORCE_SELF_UPDATE=0

usage() {
  echo "Usage: $0 [options]"
  echo "  -c, --config FILE   Use a pre-filled config file instead of prompts"
  echo "      --no-reboot     Do not reboot automatically after install"
  echo "      --skip-wipe     Skip the clean-slate wipe phase (resume after failure)"
  echo "      --no-self-update  Do not check for a newer installer version"
  echo "      --update        Update the installer scripts from GitHub and exit"
  echo "  -h, --help          Show this help"
  exit 0
}

collect_config() {
  local default_tz="UTC"
  if command -v timedatectl >/dev/null 2>&1; then
    default_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
  fi

  tty_read DOMAIN "Domain (Cloudflare zone, e.g. example.com): " ""
  [ -n "${DOMAIN:-}" ] || die "A domain is required."
  DOMAIN=$(normalize_domain "$DOMAIN")

  tty_secret CF_API_TOKEN "Cloudflare API token (hidden): "
  [ -n "${CF_API_TOKEN:-}" ] || die "A Cloudflare API token is required. Create one at https://dash.cloudflare.com/profile/api-tokens"
  echo ""

  tty_read TIMEZONE "Timezone [$default_tz]: " "$default_tz"
  TIMEZONE=${TIMEZONE:-$default_tz}

  tty_read PANEL_SUBDOMAIN "Panel subdomain [panel]: " "panel"
  PANEL_SUBDOMAIN=${PANEL_SUBDOMAIN:-panel}

  tty_read NODE_SUBDOMAIN "Node subdomain [node]: " "node"
  NODE_SUBDOMAIN=${NODE_SUBDOMAIN:-node}

  tty_read GAME_PORTS "Game port range (one TCP+UDP tunnel route per port) [25565-25575]: " "25565-25575"
  GAME_PORTS=${GAME_PORTS:-25565-25575}

  tty_read NODE_NAME "Wings node name [Node-1]: " "Node-1"
  NODE_NAME=${NODE_NAME:-Node-1}

  tty_read AUTO_REBOOT "Auto-reboot at the end to verify self-healing? [yes]: " "yes"
  AUTO_REBOOT=${AUTO_REBOOT:-yes}

  cat > "$CONF_FILE" <<EOF
DOMAIN=$DOMAIN
CF_API_TOKEN=$CF_API_TOKEN
TIMEZONE=$TIMEZONE
PANEL_SUBDOMAIN=$PANEL_SUBDOMAIN
NODE_SUBDOMAIN=$NODE_SUBDOMAIN
GAME_PORTS=$GAME_PORTS
NODE_NAME=$NODE_NAME
AUTO_REBOOT=$AUTO_REBOOT
EOF
  chmod 600 "$CONF_FILE"
  log "Configuration saved to $CONF_FILE"
}

validate_config() {
  DOMAIN=${DOMAIN:-}
  CF_API_TOKEN=${CF_API_TOKEN:-}
  PANEL_SUBDOMAIN=${PANEL_SUBDOMAIN:-panel}
  NODE_SUBDOMAIN=${NODE_SUBDOMAIN:-node}
  GAME_PORTS=${GAME_PORTS:-25565-25575}
  NODE_NAME=${NODE_NAME:-Node-1}
  TIMEZONE=${TIMEZONE:-UTC}
  AUTO_REBOOT=${AUTO_REBOOT:-yes}

  [ -n "$DOMAIN" ] || die "DOMAIN is not set in $CONF_FILE"
  [ -n "$CF_API_TOKEN" ] || die "CF_API_TOKEN is not set in $CONF_FILE"
  valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  fqdn_ok "$PANEL_SUBDOMAIN" || die "Invalid panel subdomain: $PANEL_SUBDOMAIN"
  fqdn_ok "$NODE_SUBDOMAIN" || die "Invalid node subdomain: $NODE_SUBDOMAIN"
}

cloudflare_phase() {
  banner "Phase 4/8 - Cloudflare Zero Trust (tunnel, DNS, certificates)"
  cf_full_ensure || die "Cloudflare Zero Trust setup failed."
}

install_heal_system() {
  banner "Phase 7/8 - Installing self-heal + auto-update system"
  local inst_dir=/opt/pelican-installer
  mkdir -p "$inst_dir"
  cp -rf "$SCRIPT_DIR/lib" "$inst_dir/"
  cp -rf "$SCRIPT_DIR/bin" "$inst_dir/"
  cp -rf "$SCRIPT_DIR/systemd" "$inst_dir/"
  cp -f "$SCRIPT_DIR/installer.sh" "$inst_dir/"
  cp -f "$SCRIPT_DIR/install.sh" "$inst_dir/"
  chmod +x "$inst_dir/bin/heal.sh" "$inst_dir/bin/update.sh"

  deploy_template "$SCRIPT_DIR/systemd/pelican-heal.service" /etc/systemd/system/pelican-heal.service 644
  deploy_template "$SCRIPT_DIR/systemd/pelican-heal.timer" /etc/systemd/system/pelican-heal.timer 644
  deploy_template "$SCRIPT_DIR/systemd/pelican-update.service" /etc/systemd/system/pelican-update.service 644
  deploy_template "$SCRIPT_DIR/systemd/pelican-update.timer" /etc/systemd/system/pelican-update.timer 644

  cat > /etc/logrotate.d/pelican <<EOF
$LOG_DIR/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

  systemctl daemon-reload
  systemctl enable --now pelican-heal.timer >/dev/null 2>&1
  systemctl enable --now pelican-update.timer >/dev/null 2>&1
  log "Self-heal timer active (every 5 minutes + on boot)."
  log "Auto-update timer active (weekly)."
}

finish_install() {
  banner "Installation complete"

  if ensure_node; then
    :
  else
    log_err "Wings node bootstrap deferred - the self-heal system will retry automatically."
  fi

  echo ""
  echo "  Panel:      https://$PANEL_FQDN"
  echo "  Node:       https://$NODE_FQDN"
  echo "  Game ports: tunneled via $(game_fqdn "${GAME_PORTS%%-*}") through $(game_fqdn "${GAME_PORTS##*-}")"
  echo ""
  echo "  THE ONLY MANUAL STEP:"
  echo "  Open https://$PANEL_FQDN/installer in your browser and create"
  echo "  the admin account. The node, wings, ports and routing are then"
  echo "  configured automatically within 5 minutes."
  echo ""
  echo "  Logs:   /var/log/pelican/   (install.log, heal.log, update.log)"
  echo "  Config: $CONF_FILE"
  echo ""
  log "Panel is reachable at https://$PANEL_FQDN/installer"

  if [ "$AUTO_REBOOT" = "yes" ] || [ "$AUTO_REBOOT" = "true" ]; then
    log "Rebooting in 15 seconds to verify the self-heal system (services, tunnel, DNS and Wings will all come back automatically)."
    nohup sh -c 'sleep 15; reboot' >/dev/null 2>&1 &
  else
    echo "Reboot manually when ready: sudo reboot"
  fi
}

run_phase() {
  local name=$1
  shift
  if [ -f "$STAGES_DIR/$name" ]; then
    log "Phase '$name' already completed - skipping."
    return 0
  fi
  if [ "$SKIP_WIPE" = "1" ] && [ "$name" = "wipe" ]; then
    log "Skipping wipe phase (--skip-wipe)."
    touch "$STAGES_DIR/$name"
    return 0
  fi
  if "$@"; then
    touch "$STAGES_DIR/$name"
  else
    die "Phase '$name' failed. Fix the issue and re-run - it will resume."
  fi
}

# ------------------------------------------------------------------
# main flow
# ------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) [ $# -ge 2 ] || usage; CONF_FILE_ARG=$2; shift 2 ;;
    --no-reboot) AUTO_REBOOT_FLAG=no; shift ;;
    --skip-wipe) SKIP_WIPE=1; shift ;;
    --no-self-update) NO_SELF_UPDATE=1; shift ;;
    --update) FORCE_SELF_UPDATE=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

need_root
check_os
check_arch
check_virt

mkdir -p "$PI_ROOT" "$LOG_DIR" "$LOCK_DIR"
chmod 700 "$PI_ROOT"

exec 8>"$LOCK_DIR/pelican-installer.lock"
flock -n 8 || die "Another installer/heal process is already running."

if [ "$FORCE_SELF_UPDATE" = "1" ]; then
  if self_update; then
    echo "Installer scripts are up to date (version $(pi_local_version))."
  else
    echo "Installer scripts updated to version $(pi_local_version)."
    echo "Re-run the installer to use the new version."
  fi
  exit 0
fi

if [ "${NO_SELF_UPDATE:-0}" != "1" ]; then
  if ! self_update; then
    exec bash "$SCRIPT_DIR/installer.sh" --no-self-update "$@"
  fi
fi

if [ "${CONF_FILE_ARG:-}" != "" ]; then
  cp -f "$CONF_FILE_ARG" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
fi

if [ ! -f "$CONF_FILE" ]; then
  echo ""
  echo "No configuration found yet. A few questions to set everything up:"
  echo "(answers are saved to $CONF_FILE - everything after this is automatic)"
  echo ""
  collect_config
else
  log "Using existing configuration: $CONF_FILE"
fi

set -a
. "$CONF_FILE"
set +a

validate_config

if [ "$AUTO_REBOOT_FLAG" = "no" ]; then
  AUTO_REBOOT=no
fi

PANEL_FQDN="$PANEL_SUBDOMAIN.$DOMAIN"
NODE_FQDN="$NODE_SUBDOMAIN.$DOMAIN"

# shellcheck source=../lib/wipe.sh
. "$SCRIPT_DIR/lib/wipe.sh"
# shellcheck source=../lib/base.sh
. "$SCRIPT_DIR/lib/base.sh"
# shellcheck source=../lib/panel.sh
. "$SCRIPT_DIR/lib/panel.sh"
# shellcheck source=../lib/cloudflare.sh
. "$SCRIPT_DIR/lib/cloudflare.sh"
# shellcheck source=../lib/wings.sh
. "$SCRIPT_DIR/lib/wings.sh"
# shellcheck source=../lib/node.sh
. "$SCRIPT_DIR/lib/node.sh"

STAGES_DIR="$PI_ROOT/stages"
mkdir -p "$STAGES_DIR"

run_phase wipe wipe_phase
run_phase base base_phase
run_phase panel panel_phase
run_phase cloudflare cloudflare_phase
run_phase wings wings_phase
run_phase nginx-enable nginx_enable_phase
run_phase heal-install install_heal_system
run_phase firewall ufw_setup

finish_install
