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
  echo "      --reset-admin   Reset the panel admin password (clears 2FA too)"
  echo "  -h, --help          Show this help"
  echo ""
  echo "  Wipe control: WIPE_FIRST=yes|no in the config file, or answer the"
  echo "  interactive prompt (default yes on fresh machines). The wipe never"
  echo "  touches the OS, SSH, user accounts, installer config or scripts."
  exit 0
}

print_routing_help() {
  cat <<'EOF'
  Game routing is optional and configured later (config key GAME_ROUTING).
  The panel always shows direct connection addresses (LAN + public IP) for
  every game port, plus tunnel addresses when a backend is set up:
    playit    playit.gg tunnels (public address, zero setup for players)
    bore      open-source client vs the free bore.pub relay
    frp-vps   your own VPS as relay
    direct    real router port-forwarding / UPnP (no CGNAT required)
    none      direct addresses only
EOF
}

collect_config() {
  if ! tty_available; then
    echo "No interactive terminal available for the setup questions." >&2
    echo "Pre-fill the config file (see installer.conf.example) and re-run with: --config /path/to/installer.conf" >&2
    exit 1
  fi
  local default_tz="UTC"
  if command -v timedatectl >/dev/null 2>&1; then
    default_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
  fi

  tty_read DOMAIN "Domain (Cloudflare zone, e.g. example.com): " ""
  [ -n "${DOMAIN:-}" ] || die "A domain is required."
  DOMAIN=$(normalize_domain "$DOMAIN")

  tty_secret CF_API_TOKEN "Cloudflare API token (hidden): "
  [ -n "${CF_API_TOKEN:-}" ] || die "A Cloudflare API token is required. Create one at https://dash.cloudflare.com/profile/api-tokens"
  if [ "${#CF_API_TOKEN}" -lt 20 ]; then
    log_err "Cloudflare API token looks too short (${#CF_API_TOKEN} chars) - possible paste glitch. Try again."
    tty_secret CF_API_TOKEN "Cloudflare API token (hidden): "
    [ -n "${CF_API_TOKEN:-}" ] || die "A Cloudflare API token is required."
    [ "${#CF_API_TOKEN}" -ge 20 ] || die "Cloudflare API token still too short (${#CF_API_TOKEN} chars). Paste the full token and re-run."
  fi
  echo ""

  tty_read TIMEZONE "Timezone [$default_tz]: " "$default_tz"
  TIMEZONE=${TIMEZONE:-$default_tz}
  case "$TIMEZONE" in
    utc|UTC) TIMEZONE=UTC ;;
  esac

  tty_read PANEL_SUBDOMAIN "Panel subdomain [panel]: " "panel"
  PANEL_SUBDOMAIN=${PANEL_SUBDOMAIN:-panel}

  tty_read NODE_SUBDOMAIN "Node subdomain [node]: " "node"
  NODE_SUBDOMAIN=${NODE_SUBDOMAIN:-node}

  tty_read GAME_PORTS "Game port range (TCP+UDP per port) [25565-25575]: " "25565-25575"
  GAME_PORTS=${GAME_PORTS:-25565-25575}
  valid_game_ports "$GAME_PORTS" || die "Invalid GAME_PORTS '$GAME_PORTS' (examples: 25565-25575, 27015)."

  echo ""
  print_routing_help
  echo "  (nothing to set up now - skip the playit key below if you want direct-only)"
  tty_secret PLAYIT_SECRET_KEY "playit.gg secret key (hidden, empty = direct-only): "
  echo ""

  GAME_ROUTING=${GAME_ROUTING:-playit}
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
GAME_ROUTING=$GAME_ROUTING
PLAYIT_SECRET_KEY=$PLAYIT_SECRET_KEY
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
  GAME_ROUTING=${GAME_ROUTING:-playit}
  NODE_NAME=${NODE_NAME:-Node-1}
  TIMEZONE=${TIMEZONE:-UTC}
  AUTO_REBOOT=${AUTO_REBOOT:-yes}
  WIPE_FIRST=${WIPE_FIRST:-}
  AUTO_ADMIN=${AUTO_ADMIN:-yes}

  [ -n "$DOMAIN" ] || die "DOMAIN is not set in $CONF_FILE"
  [ -n "$CF_API_TOKEN" ] || die "CF_API_TOKEN is not set in $CONF_FILE"
  valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  fqdn_ok "$PANEL_SUBDOMAIN" || die "Invalid panel subdomain: $PANEL_SUBDOMAIN"
  fqdn_ok "$NODE_SUBDOMAIN" || die "Invalid node subdomain: $NODE_SUBDOMAIN"
  valid_game_ports "$GAME_PORTS" || die "Invalid GAME_PORTS '$GAME_PORTS' in $CONF_FILE (examples: 25565-25575, 27015)."
  case "$GAME_ROUTING" in
    playit|bore|frp-vps|direct|none) ;;
    *) die "Invalid GAME_ROUTING '$GAME_ROUTING' in $CONF_FILE." ;;
  esac
}

cloudflare_phase() {
  banner "Phase 6 - Cloudflare Zero Trust (tunnel, DNS, certificates)"
  cf_full_ensure || die "Cloudflare Zero Trust setup failed."
}

install_heal_system() {
  banner "Phase 14 - Installing self-heal + auto-update system"
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
  case "$GAME_ROUTING" in
    playit) echo "  Game ports: routed via playit.gg (addresses appear on each server's Connections page)" ;;
    bore)   echo "  Game ports: routed via bore ($BORE_RELAY)" ;;
    frp-vps) echo "  Game ports: routed via frp through ${FRP_VPS_HOST:-your VPS}" ;;
    direct) echo "  Game ports: direct via router port-forwarding/UPnP" ;;
    none)   echo "  Game ports: no automatic routing configured" ;;
  esac
  echo ""
  if [ "${AUTO_ADMIN:-no}" = "yes" ]; then
    echo "  Admin login: username 'admin' - see $SECRETS_FILE for the password"
  else
    echo "  Admin setup: open https://$PANEL_FQDN/installer and complete the wizard"
    echo "               (creates your admin account + optional eggs)"
  fi
  echo "  Logs:   /var/log/pelican/   (install.log, heal.log, update.log)"
  echo "  Config: $CONF_FILE"
  echo ""
  log "Panel is reachable at https://$PANEL_FQDN"

  if [ "$AUTO_REBOOT" = "yes" ] || [ "$AUTO_REBOOT" = "true" ]; then
    local admin_done=1
    if [ "${AUTO_ADMIN:-no}" != "yes" ]; then
      count=$(mysql -N -B -e "SELECT COUNT(*) FROM pelican.users;" 2>/dev/null || echo 0)
      [ "${count:-0}" -ge 1 ] 2>/dev/null || admin_done=0
    fi
    if [ "$admin_done" = "1" ]; then
      log "Rebooting in 15 seconds to verify the self-heal system (services, tunnel, DNS and Wings will all come back automatically)."
      nohup sh -c 'sleep 15; reboot' >/dev/null 2>&1 &
    else
      echo "  Finish the setup wizard at https://$PANEL_FQDN/installer, then reboot:"
      echo "  sudo reboot"
      log "Auto-reboot deferred until the setup wizard is completed."
    fi
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
    --reset-admin) RESET_ADMIN=1; shift ;;
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

if [ "${RESET_ADMIN:-0}" = "1" ]; then
  exec bash "$SCRIPT_DIR/bin/reset-admin.sh" "$@"
fi

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

# ------------------------------------------------------------------
# optional full clean-slate reset (wipe + re-download installer from GitHub)
# ------------------------------------------------------------------
# Decided BEFORE the config is loaded: a confirmed wipe clears the config,
# stages and secrets too, then re-fetches this installer fresh - so broken
# configs (e.g. a corrupted CF token) can never survive into the next run.
if [ "$SKIP_WIPE" = "0" ]; then
  wipe_peek=""
  if [ -f "$CONF_FILE" ]; then
    wipe_peek=$(grep -E '^WIPE_FIRST=' "$CONF_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  if [ -z "$wipe_peek" ] && [ -n "${CONF_FILE_ARG:-}" ] && [ -f "$CONF_FILE_ARG" ]; then
    wipe_peek=$(grep -E '^WIPE_FIRST=' "$CONF_FILE_ARG" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  case "$wipe_peek" in
    no)
      SKIP_WIPE=1
      log "Wipe skipped (WIPE_FIRST=no)."
      ;;
    yes) : ;;
    *)
      if tty_available; then
        echo ""
        echo "Full reset: removes panel/web/database/Docker/game-tunnel data AND this"
        echo "installer's config/stages, then re-downloads the installer fresh from"
        echo "GitHub so nothing stale can break the setup."
        echo "The OS, SSH access and your user accounts are NOT touched."
        tty_read WIPE_ANSWER "Reset everything and re-download the installer? [yes/no]: " "yes"
        [ "${WIPE_ANSWER:-yes}" = "yes" ] || SKIP_WIPE=1
      elif [ -d "$PI_ROOT/stages" ] && [ -n "$(ls -A "$PI_ROOT/stages" 2>/dev/null)" ]; then
        SKIP_WIPE=1
        log "Existing install state found - skipping reset so the install can resume."
        log "Set WIPE_FIRST=yes in $CONF_FILE to force a full clean-slate reset."
      fi
      ;;
  esac
fi

if [ "$SKIP_WIPE" = "0" ]; then
  log "Downloading the latest installer from GitHub first (so a failure cannot leave the box half-wiped)..."
  reset_tmp=$(mktemp -d)
  if ! curl -fsSL -m 180 -o "$reset_tmp/pi.tar.gz" "$PI_REPO_TARBALL" || \
     ! tar -xzf "$reset_tmp/pi.tar.gz" -C "$reset_tmp"; then
    rm -rf "$reset_tmp"
    log_err "Could not download the installer tarball - aborting the reset, nothing was wiped."
    exit 1
  fi
  reset_srcdir=$(find "$reset_tmp" -maxdepth 2 -name installer.sh -printf '%h' -quit 2>/dev/null || true)
  if [ -z "$reset_srcdir" ]; then
    rm -rf "$reset_tmp"
    log_err "Downloaded tarball is invalid (installer.sh missing) - aborting the reset, nothing was wiped."
    exit 1
  fi

  log "Wiping all installer-managed data and installer state..."
  . "$SCRIPT_DIR/lib/wipe.sh"
  set +e
  wipe_phase
  set -e
  rm -rf "$PI_ROOT" /var/log/pelican /run/pelican-node-attempt
  crontab -u www-data -r >/dev/null 2>&1 || true
  mkdir -p "$LOG_DIR"

  log "Replacing the installer with the fresh GitHub copy..."
  rm -rf /opt/pelican-installer.old /opt/pelican-installer.new
  mkdir -p /opt/pelican-installer.new
  cp -rf "$reset_srcdir/." /opt/pelican-installer.new/
  mv -f /opt/pelican-installer /opt/pelican-installer.old 2>/dev/null || true
  mv -f /opt/pelican-installer.new /opt/pelican-installer
  chmod +x /opt/pelican-installer/bin/*.sh 2>/dev/null || true
  rm -rf /opt/pelican-installer.old "$reset_tmp"

  log "Reset complete - starting a fresh setup."
  exec 8>&-
  exec bash /opt/pelican-installer/installer.sh --no-self-update --skip-wipe "$@"
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
# shellcheck source=../lib/queue.sh
. "$SCRIPT_DIR/lib/queue.sh"
# shellcheck source=../lib/tune.sh
. "$SCRIPT_DIR/lib/tune.sh"
# shellcheck source=../lib/plugins.sh
. "$SCRIPT_DIR/lib/plugins.sh"
# shellcheck source=../lib/eggs.sh
. "$SCRIPT_DIR/lib/eggs.sh"
# shellcheck source=../lib/routing.sh
. "$SCRIPT_DIR/lib/routing.sh"
# shellcheck source=../lib/perfctl.sh
. "$SCRIPT_DIR/lib/perfctl.sh"

STAGES_DIR="$PI_ROOT/stages"
mkdir -p "$STAGES_DIR"

run_phase wipe wipe_phase
run_phase base base_phase
run_phase panel panel_phase
run_phase egg-images egg_images_phase
run_phase cloudflare cloudflare_phase
run_phase wings wings_phase
run_phase nginx-enable nginx_enable_phase
run_phase admin admin_phase
run_phase tune tune_phase
run_phase queue queue_phase
run_phase plugins plugins_phase
run_phase extra-eggs eggs_phase
run_phase routing routing_phase
run_phase perfctl perfctl_phase
run_phase firewall ufw_setup
run_phase heal-install install_heal_system

finish_install
