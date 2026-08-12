PLAYIT_API_BASE=https://api.playit.gg
PLAYIT_MAP_FILE="/var/www/pelican/storage/app/playit-tunnels.json"
PLAYIT_STATUS_FILE="/var/www/pelican/storage/app/playit-status.json"
PLAYIT_PUBLIC_STATE="/var/www/pelican/storage/app/pelican-public.json"

playit_api() {
  local method=$1 path=$2 body=${3:-}
  local key="${PLAYIT_API_KEY:-$PLAYIT_SECRET_KEY}"
  local args=(-sS -X "$method" "$PLAYIT_API_BASE$path" \
    -H "Authorization: Agent-Key $key" \
    -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  PLAYIT_RESP=$(curl "${args[@]}" -m 30 2>/dev/null || true)
}

playit_agent_id() {
  playit_api POST /v1/agents/rundata '{}'
  echo "$PLAYIT_RESP" | jq -r '.data.agent_id // .agent_id // empty' 2>/dev/null
}

playit_ensure_tunnels() {
  if [ -z "${PLAYIT_SECRET_KEY:-}" ] && [ -z "${PLAYIT_API_KEY:-}" ]; then
    log "No PLAYIT_SECRET_KEY configured - playit tunnels not managed (add it to $CONF_FILE)."
    return 0
  fi
  command -v docker >/dev/null 2>&1 || return 0
  if ! docker ps --format '{{.Names}}' | grep -qx playit-agent; then
    log "playit agent container not running - skipping tunnel sync."
    return 0
  fi

  local agent_id
  agent_id=$(playit_agent_id)
  [ -n "$agent_id" ] || {
    log_err "playit API: could not get agent id - check the secret key."
    return 0
  }

  local lan_ip
  lan_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  lan_ip=${lan_ip:-127.0.0.1}

  # The agent key is read-only: tunnels are created in the playit dashboard
  # (https://playit.gg -> Tunnels). This sync only maps existing tunnels to
  # allocations (matching by local port, fallback by name pelican-<port>).
  # With a write-capable API key, tunnels are auto-created here instead,
  # auto-detecting the account tier (free vs premium).
  if [ -n "${PLAYIT_API_KEY:-}" ]; then
    local has_premium ttype
    has_premium=$(echo "$PLAYIT_RESP" | jq -r '.data.permissions.has_premium // false' 2>/dev/null)
    if [ "$has_premium" = "true" ]; then
      ttype="custom-tcp"
      log "playit account: premium - using custom TCP tunnels."
    else
      ttype="minecraft-java"
      log "playit account: free - using minecraft-java tunnels (custom TCP needs premium)."
    fi
    local port ports
    ports=$(mysql -N -B -e "SELECT port FROM pelican.allocations ORDER BY port;" 2>/dev/null || true)
    for port in $ports; do
      if ! echo "$PLAYIT_RESP" | jq -e --arg n "pelican-$port" '.data.tunnels[]? | select(.name == $n)' >/dev/null 2>&1; then
        log "Creating playit tunnel for port $port..."
        playit_api POST /tunnels/create \
          "{\"name\":\"pelican-$port\",\"tunnel_type\":\"$ttype\",\"port_type\":\"tcp\",\"port_count\":1,\"origin\":{\"type\":\"agent\",\"data\":{\"agent_id\":\"$agent_id\",\"local_ip\":\"$lan_ip\",\"local_port\":$port}},\"enabled\":true}"
        if echo "$PLAYIT_RESP" | grep -q '"status":"success"'; then
          log "playit tunnel created for $port."
        else
          log_err "playit tunnel create failed for $port: $(echo "$PLAYIT_RESP" | head -c 200)"
        fi
        sleep 1
      fi
    done
  fi

  playit_api POST /v1/agents/rundata '{}'
  if echo "$PLAYIT_RESP" | jq -e . >/dev/null 2>&1; then
    mkdir -p /var/www/pelican/storage/app
    echo "$PLAYIT_RESP" | jq -r '
      [.data.tunnels[]?
       | select(.port_type == "tcp" or .port_type == "udp")
       | .agent_config.fields as $f
       | ($f[] | select(.name == "local_port") | .value) as $port
       | select($port != null)
       | {key: $port, value: .display_address}]
      | from_entries' 2>/dev/null > "$PLAYIT_MAP_FILE" || true
    chown www-data:www-data "$PLAYIT_MAP_FILE" 2>/dev/null || true
    echo "$PLAYIT_RESP" | jq -r '{has_premium: .data.permissions.has_premium, account_status: .data.permissions.account_status, agent_id: .data.agent_id}' 2>/dev/null > "$PLAYIT_STATUS_FILE" || true
    chown www-data:www-data "$PLAYIT_STATUS_FILE" 2>/dev/null || true
    local cf_app="false"
    if grep -q '^CF_APP_ROUTING\s*=\s*yes' "$CONF_FILE" 2>/dev/null; then
      cf_app="true"
    fi
    echo "{\"domain\":\"$DOMAIN\",\"cf_app_routing\":$cf_app}" > "$PLAYIT_PUBLIC_STATE"
    chown www-data:www-data "$PLAYIT_PUBLIC_STATE" 2>/dev/null || true
    log "playit tunnel map updated ($PLAYIT_MAP_FILE)."
  fi
}

playit_phase() {
  if [ -z "${PLAYIT_SECRET_KEY:-}" ]; then
    log "No PLAYIT_SECRET_KEY configured - playit agent skipped (add it to $CONF_FILE to enable)."
    return 0
  fi
  banner "Phase - Deploying playit.gg agent"
  docker rm -f playit-agent >/dev/null 2>&1 || true
  docker run -d --restart unless-stopped --name playit-agent --net=host \
    -e SECRET_KEY="$PLAYIT_SECRET_KEY" \
    ghcr.io/playit-cloud/playit-agent:1.0 >>"$INSTALL_LOG" 2>&1 || {
    log_err "playit agent failed to start - check 'docker logs playit-agent'."
    return 0
  }
  sleep 6
  if docker ps --format '{{.Names}}' | grep -qx playit-agent; then
    log "playit agent running (create TCP tunnels at https://playit.gg -> Tunnels)."
  fi
  playit_ensure_tunnels
}
