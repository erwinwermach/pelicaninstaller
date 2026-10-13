base_phase() {
  banner "Phase 2 - Base system update"
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  log "Checking network connectivity..."
  wait_network 120 || die "No network access. Fix connectivity and re-run."

  log "Updating Ubuntu package lists..."
  run_with_heartbeat "apt-get update" 600 \
    apt-get -y -o DPkg::Lock::Timeout=300 update \
    || log_err "apt-get update had problems - continuing with the existing package lists."

  log "Upgrading all installed packages (a first run on a fresh server can take 10-40+ minutes; progress is written to $INSTALL_LOG)..."
  run_with_heartbeat "apt-get full-upgrade" 10800 \
    apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade \
    || log_err "apt-get full-upgrade had problems - continuing."
  dpkg --configure -a >>"$INSTALL_LOG" 2>&1 || true

  log "Installing base packages..."
  run_with_heartbeat "base package install" 1800 \
    apt-get -y -o DPkg::Lock::Timeout=600 install curl wget git unzip zip tar xz-utils gnupg ca-certificates \
    software-properties-common lsb-release ufw fail2ban unattended-upgrades jq \
    openssl dnsutils \
    || die "Failed to install base packages."

  log "Configuring swap..."
  if ! swapon --show 2>/dev/null | grep -q .; then
    if [ ! -f /swapfile ]; then
      fallocate -l 2G /swapfile 2>/dev/null \
        || run_with_heartbeat "swapfile creation (dd)" 900 dd if=/dev/zero of=/swapfile bs=1M count=2048 \
        || true
    fi
    if [ -f /swapfile ]; then
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null 2>&1 || true
      swapon /swapfile >/dev/null 2>&1 || true
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
      echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
    fi
  fi

  log "Enabling unattended security upgrades with automatic reboot..."
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
    sed -i 's|^//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
    sed -i 's|^Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
  fi

  log "Setting hostname and timezone..."
  hostnamectl set-hostname pelican 2>/dev/null || true
  if [ -n "${TIMEZONE:-}" ]; then
    timedatectl set-timezone "$TIMEZONE" >/dev/null 2>&1 || true
  fi

  log "Ensuring system service accounts are not expired (blocks mariadbd/other daemons)..."
  local sysuser
  for sysuser in mysql www-data redis; do
    if id "$sysuser" >/dev/null 2>&1; then
      chage -E -1 -m 0 -M 99999 -I -1 "$sysuser" >/dev/null 2>&1 || true
      usermod -U "$sysuser" >/dev/null 2>&1 || true
    fi
  done

  log "Starting fail2ban (SSH protection)..."
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
}
