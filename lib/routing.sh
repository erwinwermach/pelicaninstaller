GAME_ROUTING=${GAME_ROUTING:-playit}
BORE_RELAY=${BORE_RELAY:-bore.pub}
BORE_VERSION=v0.5.0
FRP_VERSION=v0.61.1
PLAYIT_API_BASE=https://api.playit.gg

routing_ports() {
  expand_ports "${GAME_PORTS:-25565-25575}"
}

routing_phase() {
  banner "Phase 12 - Game routing ($GAME_ROUTING)"
  case "$GAME_ROUTING" in
    playit)
      playit_deploy || log_err "playit setup had problems - direct connection addresses still shown in the panel."
      ;;
    bore)
      bore_deploy || log_err "bore setup had problems - direct connection addresses still shown in the panel."
      ;;
    frp-vps)
      frp_vps_deploy || log_err "frp setup had problems - direct connection addresses still shown in the panel."
      ;;
    direct)
      direct_deploy
      ;;
    none)
      log "No tunnel backend configured (GAME_ROUTING=none) - direct connection addresses still shown in the panel."
      ;;
    *)
      log_err "Unknown GAME_ROUTING='$GAME_ROUTING' (use playit|bore|frp-vps|direct|none). Falling back to direct-only."
      ;;
  esac
  routing_sync
  return 0
}

routing_enabled_backends() {
  case "$GAME_ROUTING" in
    playit) echo playit ;;
    bore) echo bore ;;
    frp-vps) echo frp ;;
    direct) echo direct ;;
    *) echo "" ;;
  esac
}

routing_write_state() {
  local domain_json="$1" backends_json="$2" ports_json="$3" cf_json="$4"
  mkdir -p "$(dirname "$ROUTES_STATE_FILE")"
  printf '{"domain":%s,"updated":"%s","backends":%s,"ports":%s,"cf_app":%s}\n' \
    "$domain_json" "$(date -Is)" "$backends_json" "$ports_json" "$cf_json" \
    > "$ROUTES_STATE_FILE.tmp" 2>/dev/null || return 1
  if jq -e . "$ROUTES_STATE_FILE.tmp" >/dev/null 2>&1; then
    chown www-data:www-data "$ROUTES_STATE_FILE.tmp" 2>/dev/null || true
    chmod 644 "$ROUTES_STATE_FILE.tmp"
    mv -f "$ROUTES_STATE_FILE.tmp" "$ROUTES_STATE_FILE"
  else
    rm -f "$ROUTES_STATE_FILE.tmp"
  fi
}

routing_domain_json() {
  if [ -n "${DOMAIN:-}" ]; then
    printf '"%s"' "$DOMAIN"
  else
    echo null
  fi
}

routing_cf_app_json() {
  local out="[" first=1 app
  if [ "${CF_APP_ROUTING:-no}" = "yes" ] && [ -n "${DOMAIN:-}" ]; then
    for app in $(cf_app_hostnames); do
      [ $first -eq 1 ] || out="$out,"
      first=0
      out="$out\"$app\""
    done
  fi
  echo "$out]"
}

routing_lan_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
}

routing_fallback_json() {
  local lan pub
  lan=$(routing_lan_ip)
  [ -n "$lan" ] || lan=127.0.0.1
  pub=""
  wan_ip_is_usable && pub=$(public_ip)
  local port out="{" first=1
  for port in $(routing_ports); do
    [ $first -eq 1 ] || out="$out,"
    first=0
    out="$out\"$port\":["
    out="$out{\"backend\":\"direct\",\"address\":\"$lan:$port\",\"note\":\"direct (LAN)\"}"
    if [ -n "$pub" ]; then
      out="$out,{\"backend\":\"direct\",\"address\":\"$pub:$port\",\"note\":\"direct (public)\"}"
    fi
    out="$out]"
  done
  echo "$out}"
}

routing_sync() {
  command -v jq >/dev/null 2>&1 || return 0
  local backends='{}'
  local backend
  for backend in $(routing_enabled_backends); do
    backends=$(printf '%s' "$backends" | jq --arg b "$backend" '.[$b] = {"active": true}')
  done

  local pjson='{}'
  case "$GAME_ROUTING" in
    playit) pjson=$(playit_addresses_json) ;;
    bore) pjson=$(bore_addresses_json) ;;
    frp-vps) pjson=$(frp_addresses_json) ;;
    direct) pjson=$(direct_addresses_json) ;;
    *) pjson='{}' ;;
  esac
  if ! printf '%s' "$pjson" | jq -e . >/dev/null 2>&1; then
    pjson='{}'
  fi

  local fjson ports
  fjson=$(routing_fallback_json)
  if printf '%s' "$fjson" | jq -e . >/dev/null 2>&1; then
    ports=$(jq -n --argjson f "$fjson" --argjson b "$pjson" '
      ($f + $b) | with_entries(.value = (($f[.key] // []) + ($b[.key] // [])))
    ')
  else
    ports="$pjson"
  fi
  [ -n "$ports" ] || ports='{}'

  routing_write_state "$(routing_domain_json)" "$backends" "$ports" "$(routing_cf_app_json)"
  log "Routing state updated: $ROUTES_STATE_FILE"
}

# ------------------------------------------------------------------
# playit.gg backend
# ------------------------------------------------------------------

playit_api() {
  local method=$1 path=$2 body=${3:-}
  local key="${PLAYIT_API_KEY:-$PLAYIT_SECRET_KEY}"
  [ -n "$key" ] || key=$(panel_env_get PLAYIT_API_KEY)
  [ -n "$key" ] || { PLAYIT_RESP=""; return 1; }
  local args=(-sS -X "$method" "$PLAYIT_API_BASE$path" \
    -H "Authorization: Agent-Key $key" \
    -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  PLAYIT_RESP=$(curl "${args[@]}" -m 30 2>/dev/null || true)
}

playit_agent_id() {
  playit_api POST /v1/agents/rundata '{}' || return 1
  echo "$PLAYIT_RESP" | jq -r '.data.agent_id // .agent_id // empty' 2>/dev/null
}

playit_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx playit-agent
}

playit_agent_ensure() {
  if [ -z "${PLAYIT_SECRET_KEY:-}" ]; then
    PLAYIT_SECRET_KEY=$(panel_env_get PLAYIT_SECRET_KEY)
  fi
  [ -n "${PLAYIT_SECRET_KEY:-}" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  if playit_container_running; then
    return 0
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx playit-agent; then
    docker start playit-agent >/dev/null 2>&1 && log "playit agent restarted."
  else
    docker rm -f playit-agent >/dev/null 2>&1 || true
    docker run -d --restart unless-stopped --name playit-agent --net=host \
      -e SECRET_KEY="$PLAYIT_SECRET_KEY" \
      ghcr.io/playit-cloud/playit-agent:1.0 >>"$INSTALL_LOG" 2>&1 \
      && log "playit agent (re)started." \
      || log_err "playit agent failed to start - check 'docker logs playit-agent'."
  fi
  sleep 3
  return 0
}

playit_deploy() {
  if [ -z "${PLAYIT_SECRET_KEY:-}" ]; then
    PLAYIT_SECRET_KEY=$(panel_env_get PLAYIT_SECRET_KEY)
  fi
  if [ -z "${PLAYIT_SECRET_KEY:-}" ]; then
    log "No PLAYIT_SECRET_KEY configured - playit skipped; direct connection addresses are shown in the panel instead."
    return 0
  fi
  playit_agent_ensure
  if playit_container_running; then
    log "playit agent running."
  fi
  playit_create_tunnels
}

playit_create_tunnels() {
  if [ -z "${PLAYIT_API_KEY:-}" ]; then
    PLAYIT_API_KEY=$(panel_env_get PLAYIT_API_KEY)
  fi
  [ -n "${PLAYIT_API_KEY:-}" ] || return 0
  playit_container_running || return 0
  local agent_id
  agent_id=$(playit_agent_id) || {
    log_err "playit API: could not get agent id - check the keys."
    return 0
  }

  local has_premium ttype
  has_premium=$(echo "$PLAYIT_RESP" | jq -r '.data.permissions.has_premium // false' 2>/dev/null)
  if [ "$has_premium" = "true" ]; then
    ttype="custom-tcp"
    log "playit account: premium - using custom TCP tunnels."
  else
    ttype="minecraft-java"
    log "playit account: free - using minecraft-java tunnels (custom TCP needs premium)."
  fi

  local lan_ip port existing
  lan_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  lan_ip=${lan_ip:-127.0.0.1}

  local db_ports=""
  if command -v mysql >/dev/null 2>&1; then
    db_ports=$(mysql -N -B -e "SELECT DISTINCT port FROM pelican.allocations ORDER BY port;" 2>/dev/null || true)
  fi
  local wanted
  wanted="$(routing_ports) $db_ports"

  playit_api POST /v1/agents/rundata '{}'
  for port in $(echo "$wanted" | tr ' ' '\n' | sort -un); do
    existing=$(echo "$PLAYIT_RESP" | jq -r --arg n "pelican-$port" \
      '.data.tunnels[]? | select((.name // "") == $n) | .id' 2>/dev/null | head -1)
    [ -n "$existing" ] && continue
    log "Creating playit tunnel for port $port..."
    playit_api POST /tunnels/create \
      "{\"name\":\"pelican-$port\",\"tunnel_type\":\"$ttype\",\"port_type\":\"tcp\",\"port_count\":1,\"origin\":{\"type\":\"agent\",\"data\":{\"agent_id\":\"$agent_id\",\"local_ip\":\"$lan_ip\",\"local_port\":$port}},\"enabled\":true}"
    if echo "$PLAYIT_RESP" | grep -q '"status":"success"'; then
      log "playit tunnel created for $port."
    else
      log_err "playit tunnel create failed for $port: $(echo "$PLAYIT_RESP" | head -c 200)"
    fi
    sleep 1
  done
}

playit_addresses_json() {
  playit_api POST /v1/agents/rundata '{}' || { echo '{}'; return 0; }
  echo "$PLAYIT_RESP" | jq '
    [.data.tunnels[]?
     | select(.port_type == "tcp" or .port_type == "udp")
     | .agent_config.fields as $f
     | ($f[]? | select(.name == "local_port") | (.value | tostring)) as $port
     | select($port != null)
     | {($port): [{"backend": "playit", "address": .display_address}]}]
    | add // {}' 2>/dev/null || echo '{}'
}

# ------------------------------------------------------------------
# bore backend (open-source, free public relay; address port changes on restart)
# ------------------------------------------------------------------

bore_download_url() {
  local target
  case "$(uname -m)" in
    x86_64) target=x86_64-unknown-linux-musl ;;
    aarch64) target=aarch64-unknown-linux-musl ;;
    *) return 1 ;;
  esac
  echo "https://github.com/ekzhang/bore/releases/download/$BORE_VERSION/bore-$BORE_VERSION-$target.tar.gz"
}

bore_install_binary() {
  [ -x "$BORE_BIN" ] && "$BORE_BIN" --version >/dev/null 2>&1 && return 0
  local url tmp
  url=$(bore_download_url) || { log_err "bore: unsupported architecture."; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL -m 120 -o "$tmp/bore.tgz" "$url" >>"$INSTALL_LOG" 2>&1 || { rm -rf "$tmp"; log_err "bore download failed."; return 1; }
  tar -xzf "$tmp/bore.tgz" -C "$tmp" >>"$INSTALL_LOG" 2>&1 || { rm -rf "$tmp"; return 1; }
  find "$tmp" -type f -name bore -exec cp -f {} "$BORE_BIN" \; 2>/dev/null
  rm -rf "$tmp"
  chmod +x "$BORE_BIN"
  [ -x "$BORE_BIN" ]
}

bore_deploy() {
  bore_install_binary || return 1
  local unit=/etc/systemd/system/bore@.service
  cat > "$unit" <<EOF
[Unit]
Description=bore tunnel for game port %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=BORE_RELAY=$BORE_RELAY
ExecStart=$BORE_BIN local %i --to \$BORE_RELAY
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  local port
  for port in $(routing_ports); do
    systemctl enable --now "bore@$port" >>"$INSTALL_LOG" 2>&1 || true
  done
  sleep 4
  log "bore tunnels active against relay $BORE_RELAY."
  log "NOTE: relay addresses change whenever these services restart - players re-check the panel Connections page."
}

bore_assigned_port() {
  local unit_port=$1 out=""
  out=$(journalctl -u "bore@$unit_port" -n 40 --no-pager -o cat 2>/dev/null \
    | grep -oE "[A-Za-z0-9.-]+:[0-9]{2,5}" | tail -1)
  echo "$out"
}

bore_addresses_json() {
  local port addr out="{" first=1
  for port in $(routing_ports); do
    systemctl is-active --quiet "bore@$port" 2>/dev/null || continue
    addr=$(bore_assigned_port "$port")
    [ -n "$addr" ] || continue
    [ $first -eq 1 ] || out="$out,"
    first=0
    out="$out\"$port\":[{\"backend\":\"bore\",\"address\":\"$addr\",\"note\":\"changes on service restart\"}]"
  done
  echo "$out}"
}

# ------------------------------------------------------------------
# frp-on-your-VPS backend (works with free-tier VMs, e.g. Oracle Always Free)
# ------------------------------------------------------------------

frp_arch_name() {
  case "$(uname -m)" in
    x86_64) echo linux_amd64 ;;
    aarch64) echo linux_arm64 ;;
    *) return 1 ;;
  esac
}

frp_load_vps_config() {
  if [ -f "$SECRETS_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set +a
  fi
  if [ -z "${FRP_VPS_HOST:-}" ]; then
    tty_read FRP_VPS_HOST "VPS hostname or IP (public, e.g. your Oracle/AWS free VM): " ""
    [ -n "${FRP_VPS_HOST:-}" ] || { log_err "No VPS host given - frp backend aborted."; return 1; }
  fi
  if [ -z "${FRP_VPS_USER:-}" ]; then
    tty_read FRP_VPS_USER "VPS SSH user [root]: " "root"
  fi
  FRP_VPS_PORT=${FRP_VPS_PORT:-22}
  if [ -z "${FRP_VPS_KEY:-}" ]; then
    tty_read FRP_VPS_KEY "SSH private key path (empty = password login): " ""
  fi
  if [ -z "${FRP_VPS_KEY:-}" ] && [ -z "${FRP_VPS_PASS:-}" ]; then
    tty_secret FRP_VPS_PASS "VPS SSH password (hidden): "
  fi
  {
    echo "FRP_VPS_HOST=$FRP_VPS_HOST"
    echo "FRP_VPS_USER=$FRP_VPS_USER"
    echo "FRP_VPS_PORT=$FRP_VPS_PORT"
    echo "FRP_VPS_KEY=$FRP_VPS_KEY"
  } >> "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE" 2>/dev/null || true
  if [ -n "${FRP_VPS_PASS:-}" ]; then
    grep -q '^FRP_VPS_PASS=' "$SECRETS_FILE" 2>/dev/null || echo "FRP_VPS_PASS=$FRP_VPS_PASS" >> "$SECRETS_FILE"
  fi
  return 0
}

frp_ssh() {
  local cmd=$1
  local ssh_args=(-p "$FRP_VPS_PORT" -o BatchMode=no -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  [ -n "${FRP_VPS_KEY:-}" ] && ssh_args+=(-i "$FRP_VPS_KEY")
  if [ -n "${FRP_VPS_PASS:-}" ]; then
    command -v sshpass >/dev/null 2>&1 || apt-get install -y sshpass >>"$INSTALL_LOG" 2>&1 || { log_err "sshpass unavailable."; return 1; }
    sshpass -p "$FRP_VPS_PASS" ssh "${ssh_args[@]}" "$FRP_VPS_USER@$FRP_VPS_HOST" "$cmd"
  else
    ssh "${ssh_args[@]}" "$FRP_VPS_USER@$FRP_VPS_HOST" "$cmd"
  fi
}

frp_token_file() {
  echo "$PI_ROOT/frp-token"
}

frp_shared_token() {
  local f
  f=$(frp_token_file)
  if [ ! -s "$f" ]; then
    random_hex 24 > "$f"
    chmod 600 "$f"
  fi
  cat "$f"
}

frp_bind_port() {
  echo "${FRP_BIND_PORT:-7000}"
}

frp_vps_deploy() {
  frp_load_vps_config || return 1
  local arch token bind_port
  arch=$(frp_arch_name) || { log_err "frp: unsupported architecture."; return 1; }
  token=$(frp_shared_token)
  bind_port=$(frp_bind_port)

  log "Testing SSH connection to $FRP_VPS_USER@$FRP_VPS_HOST..."
  frp_ssh "echo ok" >>"$INSTALL_LOG" 2>&1 || {
    log_err "SSH to the VPS failed. Verify host/user/password/key and try again."
    return 1
  }

  log "Installing frps on the VPS (idempotent)..."
  local game_ports_csv
  game_ports_csv=$(routing_ports | paste -sd,)
  frp_ssh "bash -s" <<REMOTE_SCRIPT >>"$INSTALL_LOG" 2>&1 || {
set -e
if [ "\$(id -u)" -ne 0 ]; then echo "need-root"; exit 1; fi
mkdir -p /opt/frp && cd /opt/frp
VER=$FRP_VERSION
ARCH=$arch
if [ ! -x /usr/local/bin/frps ]; then
  curl -fsSL -m 120 -o frp.tgz "https://github.com/fatedier/frp/releases/download/\$VER/frp_\${VER#v}_\$ARCH.tar.gz"
  tar -xzf frp.tgz
  cp "frp_\${VER#v}_\$ARCH/frps" /usr/local/bin/frps
fi
cat > /etc/frps.toml <<TOML
bindAddr = "0.0.0.0"
bindPort = $bind_port
auth.token = "$token"
TOML
cat > /etc/systemd/system/frps.service <<UNIT
[Unit]
Description=frp server (pelican)
After=network-online.target
[Service]
ExecStart=/usr/local/bin/frps -c /etc/frps.toml
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now frps
if command -v ufw >/dev/null 2>&1; then ufw allow $bind_port/tcp || true; for p in $(echo "$game_ports_csv" | tr , ' '); do ufw allow \$p/tcp || true; ufw allow \$p/udp || true; done; fi
echo frps-ready
REMOTE_SCRIPT
    log_err "frps installation on the VPS failed - see $INSTALL_LOG."
    log_err "If the VM uses a cloud firewall (security list), open TCP $bind_port plus the game ports $game_ports_csv TCP+UDP manually."
    return 1
  }

  frp_install_client
  frp_write_client_config "$token" "$bind_port"
  systemctl enable --now frpc >>"$INSTALL_LOG" 2>&1 || true
  sleep 3
  if systemctl is-active --quiet frpc; then
    log "frp tunnels active: $FRP_VPS_HOST:<game ports> (TCP+UDP)."
    log "Remember: the VPS provider firewall/security list must allow those ports."
  else
    log_err "frpc not running - check 'journalctl -u frpc'."
  fi
}

frp_install_client() {
  [ -x "$FRPC_BIN" ] && return 0
  local arch ver="$FRP_VERSION" tmp
  arch=$(frp_arch_name) || return 1
  tmp=$(mktemp -d)
  curl -fsSL -m 120 -o "$tmp/frp.tgz" \
    "https://github.com/fatedier/frp/releases/download/$ver/frp_${ver#v}_${arch}.tar.gz" >>"$INSTALL_LOG" 2>&1 \
    || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/frp.tgz" -C "$tmp" >>"$INSTALL_LOG" 2>&1
  cp -f "$tmp/frp_${ver#v}_${arch}/frpc" "$FRPC_BIN" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  chmod +x "$FRPC_BIN"
}

frp_write_client_config() {
  local token=$1 bind_port=$2
  mkdir -p "$PI_ROOT"
  cat > "$PI_ROOT/frpc.toml" <<EOF
serverAddr = "$FRP_VPS_HOST"
serverPort = $bind_port
auth.token = "$token"

transport.poolCount = 4
transport.tcpMuxKeepaliveInterval = 30
EOF
  local port
  {
    for port in $(routing_ports); do
      echo "[[proxies]]"
      echo "name = \"pelican-$port-tcp\""
      echo "type = \"tcp\""
      echo "localIP = \"127.0.0.1\""
      echo "localPort = $port"
      echo "remotePort = $port"
      echo ""
      echo "[[proxies]]"
      echo "name = \"pelican-$port-udp\""
      echo "type = \"udp\""
      echo "localIP = \"127.0.0.1\""
      echo "localPort = $port"
      echo "remotePort = $port"
      echo ""
    done
  } >> "$PI_ROOT/frpc.toml"
  chmod 600 "$PI_ROOT/frpc.toml"

  if [ ! -f /etc/systemd/system/frpc.service ]; then
    cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=frp client (pelican game tunnels)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$FRPC_BIN -c $PI_ROOT/frpc.toml
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  elif ! grep -q "frpc.toml" /etc/systemd/system/frpc.service; then
    sed -i "s|^ExecStart=.*|ExecStart=$FRPC_BIN -c $PI_ROOT/frpc.toml|" /etc/systemd/system/frpc.service
    systemctl daemon-reload
  fi
}

frp_addresses_json() {
  [ -f "$PI_ROOT/frpc.toml" ] || { echo '{}'; return 0; }
  systemctl is-active --quiet frpc 2>/dev/null || { echo '{}'; return 0; }
  local host="${FRP_VPS_HOST:-$(grep -E '^serverAddr' "$PI_ROOT/frpc.toml" 2>/dev/null | cut -d'"' -f2)}"
  [ -n "$host" ] || { echo '{}'; return 0; }
  local port out="{" first=1
  for port in $(routing_ports); do
    [ $first -eq 1 ] || out="$out,"
    first=0
    out="$out\"$port\":[{\"backend\":\"frp\",\"address\":\"$host:$port\",\"note\":\"via your VPS\"}]"
  done
  echo "$out}"
}

# ------------------------------------------------------------------
# direct backend (router port-forwarding / UPnP, real public IP required)
# ------------------------------------------------------------------

direct_deploy() {
  if ! wan_ip_is_usable; then
    log "This host sits behind CGNAT - the direct backend cannot work here."
    log "Switch GAME_ROUTING to playit, bore or frp-vps (see $CONF_FILE)."
    return 0
  fi
  upnp_ensure
}

direct_addresses_json() {
  wan_ip_is_usable || { echo '{}'; return 0; }
  local port pub out="{" first=1
  pub=$(public_ip)
  for port in $(routing_ports); do
    [ $first -eq 1 ] || out="$out,"
    first=0
    out="$out\"$port\":[{\"backend\":\"direct\",\"address\":\"$pub:$port\",\"note\":\"requires router port-forward/UPnP\"}]"
  done
  echo "$out}"
}
