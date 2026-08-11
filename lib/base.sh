base_phase() {
  banner "Phase 2/8 - Base system update"
  export DEBIAN_FRONTEND=noninteractive

  log "Updating Ubuntu..."
  wait_network 60 || die "No network access. Fix connectivity and re-run."
  apt-get update -y >>"$INSTALL_LOG" 2>&1 || true
  apt-get full-upgrade -y >>"$INSTALL_LOG" 2>&1 || true

  log "Installing base packages..."
  apt-get install -y curl wget git unzip zip tar xz-utils gnupg ca-certificates \
    software-properties-common lsb-release ufw fail2ban unattended-upgrades jq \
    openssl dnsutils >>"$INSTALL_LOG" 2>&1 || die "Failed to install base packages."

  log "Configuring swap..."
  if ! swapon --show 2>/dev/null | grep -q .; then
    if [ ! -f /swapfile ]; then
      fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 >>"$INSTALL_LOG" 2>&1 || true
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

  log "Starting fail2ban (SSH protection)..."
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
}
