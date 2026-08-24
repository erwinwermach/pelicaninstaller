wings_install_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Docker already running."
    wings_docker_daemon_tuning
    return 0
  fi
  log "Installing Docker CE (this can take a few minutes)..."
  curl -fsSL -m 120 https://get.docker.com -o /tmp/get-docker.sh >>"$INSTALL_LOG" 2>&1 || return 1
  CHANNEL=stable sh /tmp/get-docker.sh >>"$INSTALL_LOG" 2>&1 || return 1
  systemctl enable docker >>"$INSTALL_LOG" 2>&1 || true
  ensure_service docker 6 || return 1
  wings_docker_daemon_tuning
}

wings_docker_daemon_tuning() {
  if [ ! -f /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"},
    "live-restore": true
}
EOF
    restart_service docker
  elif ! grep -q 'max-size' /etc/docker/daemon.json; then
    jq '. + {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}, "live-restore": true}' \
      /etc/docker/daemon.json > /etc/docker/daemon.json.tmp 2>/dev/null \
      && mv -f /etc/docker/daemon.json.tmp /etc/docker/daemon.json && restart_service docker
  fi
}

wings_install_binary() {
  if [ -x "$WINGS_BIN" ] && "$WINGS_BIN" --version >/dev/null 2>&1; then
    log "Wings already installed."
    return 0
  fi
  log "Downloading Wings..."
  curl -fsSL -m 120 -o "$WINGS_BIN" \
    "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_$(arch_map)" >>"$INSTALL_LOG" 2>&1 \
    || return 1
  chmod +x "$WINGS_BIN"
}

wings_write_unit() {
  cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Wings Daemon
After=docker.service network-online.target
Requires=docker.service
PartOf=docker.service
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=65535
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

wings_phase() {
  banner "Phase 7 - Docker + Wings"
  mkdir -p "$PELICAN_ETC" /var/run/wings
  wings_install_docker || die "Docker installation failed."
  wings_install_binary || die "Wings download failed."
  wings_write_unit
  systemctl enable wings >/dev/null 2>&1 || true
}
