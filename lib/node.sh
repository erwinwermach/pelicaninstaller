APP_API_BASE="https://127.0.0.1:8443/api/application"
NODE_ATTEMPT_FILE=/run/pelican-node-attempt

panel_admin_exists() {
  [ -f "$PANEL_DIR/.env" ] || return 1
  local count
  count=$(mysql -N -B -e "SELECT COUNT(*) FROM pelican.users;" 2>/dev/null || echo 0)
  [ "${count:-0}" -ge 1 ] 2>/dev/null
}

app_api() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -X "$method" "$APP_API_BASE$path" \
    -H "Authorization: Bearer ${API_KEY_ID}${API_KEY_SECRET}" \
    -H "Accept: application/vnd.pelican.panel+json; version=1" \
    -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  APP_RESP=$(curl "${args[@]}" -m 30 -k -w $'\n%{http_code}' 2>/dev/null || true)
  APP_CODE=${APP_RESP##*$'\n'}
  APP_RESP=${APP_RESP%$'\n'*}
}

ensure_app_api_key() {
  if [ -f "$API_KEY_FILE" ]; then
    API_KEY_ID=$(grep -E '^API_KEY_ID=' "$API_KEY_FILE" | cut -d= -f2-)
    API_KEY_SECRET=$(grep -E '^API_KEY_SECRET=' "$API_KEY_FILE" | cut -d= -f2-)
    if [ -n "$API_KEY_ID" ] && [ -n "$API_KEY_SECRET" ]; then
      app_api GET /nodes
      if [ "$APP_CODE" = "200" ]; then
        return 0
      fi
    fi
    log "Stored panel API key invalid - recreating."
  fi

  local id secret perms
  id="papp_$(random_hex 12 | cut -c1-11)"
  secret=$(random_hex 16)
  perms="['server' => 3, 'node' => 3, 'allocation' => 3, 'user' => 3, 'egg' => 3, 'database_host' => 3, 'database' => 3, 'mount' => 3, 'role' => 3, 'plugin' => 3]"

  log "Creating panel Application API key..."
  (cd "$PANEL_DIR" && php artisan tinker --execute="\App\Models\ApiKey::create(['user_id' => 1, 'key_type' => 2, 'identifier' => '$id', 'token' => '$secret', 'memo' => 'auto-installer', 'permissions' => $perms, 'allowed_ips' => []]);") >>"$INSTALL_LOG" 2>&1 || true

  API_KEY_ID=$id
  API_KEY_SECRET=$secret
  app_api GET /nodes
  if [ "$APP_CODE" != "200" ]; then
    log_err "API key creation failed (API responded $APP_CODE): $APP_RESP"
    log_err "The panel may still be initializing - the self-heal system will retry automatically."
    return 1
  fi

  cat > "$API_KEY_FILE" <<EOF
API_KEY_ID=$id
API_KEY_SECRET=$secret
EOF
  chmod 600 "$API_KEY_FILE"
  log "Panel API key ready."
}

node_resources() {
  local mem_kb disk_kb mem_mb disk_mb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  mem_mb=$(( mem_kb / 1024 - 1024 ))
  disk_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  disk_mb=$(( disk_kb / 1024 - 10240 ))
  [ "$mem_mb" -lt 512 ] && mem_mb=512
  [ "$disk_mb" -lt 1024 ] && disk_mb=1024
  NODE_MEMORY=${NODE_MEMORY:-$mem_mb}
  NODE_DISK=${NODE_DISK:-$disk_mb}
  NODE_CPU=${NODE_CPU:-100}
}

ensure_node_record() {
  app_api GET /nodes
  local existing
  existing=$(echo "$APP_RESP" | jq -r --arg f "$NODE_FQDN" '.data[]? | select(.attributes.fqdn == $f) | .attributes.id // empty' 2>/dev/null)
  if [ -n "$existing" ]; then
    NODE_ID=$existing
    return 0
  fi

  node_resources
  local body
  body=$(jq -nc \
    --arg name "${NODE_NAME:-Node-1}" \
    --arg fqdn "$NODE_FQDN" \
    --argjson memory "$NODE_MEMORY" \
    --argjson disk "$NODE_DISK" \
    --argjson cpu "$NODE_CPU" \
    '{name: $name, description: "auto-installed", public: true, fqdn: $fqdn, scheme: "https", behind_proxy: true, daemon_base: "/var/lib/pelican/volumes", daemon_sftp: 2022, daemon_listen: 8080, daemon_connect: 443, memory: $memory, memory_overallocate: 0, disk: $disk, disk_overallocate: 0, cpu: $cpu, cpu_overallocate: 0, upload_size: 100, maintenance_mode: false}')

  log "Creating node '$NODE_NAME' ($NODE_FQDN)..."
  app_api POST /nodes "$body"
  if [ "$APP_CODE" != "201" ] && [ "$APP_CODE" != "200" ]; then
    log_err "Node creation failed (API responded $APP_CODE): $APP_RESP"
    return 1
  fi
  NODE_ID=$(echo "$APP_RESP" | jq -r '.attributes.id // empty' 2>/dev/null)
  [ -n "$NODE_ID" ] || return 1
}

ensure_node_allocations() {
  app_api GET "/nodes/$NODE_ID/allocations"
  local existing_ports new_ports
  existing_ports=$(echo "$APP_RESP" | jq -r '.data[].attributes.port // empty' 2>/dev/null)

  new_ports=""
  local port
  for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
    if ! echo "$existing_ports" | grep -qx "$port"; then
      new_ports="$new_ports $port"
    fi
  done

  if [ -z "$new_ports" ]; then
    return 0
  fi

  log "Allocating game ports:$new_ports"
  local json
  json=$(jq -nc --arg ip "127.0.0.1" --argjson ports "[$(for p in $new_ports; do echo -n "\"$p\","; done | sed 's/,$//')]" '{ip: $ip, ports: $ports}')
  app_api POST "/nodes/$NODE_ID/allocations" "$json"
  if [ "$APP_CODE" != "201" ] && [ "$APP_CODE" != "200" ]; then
    log_err "Bulk allocation failed ($APP_CODE) - retrying per port."
    local ok=0
    for port in $new_ports; do
      app_api POST "/nodes/$NODE_ID/allocations" "{\"ip\":\"127.0.0.1\",\"ports\":[\"$port\"]}"
      if [ "$APP_CODE" = "201" ] || [ "$APP_CODE" = "200" ]; then
        ok=1
      fi
    done
    if [ "$ok" = "0" ]; then
      log_err "Allocation failed: $APP_RESP"
      return 1
    fi
  fi
}

ensure_wings_config() {
  app_api GET "/nodes/$NODE_ID/configuration"
  if [ "$APP_CODE" != "200" ]; then
    log_err "Could not fetch node configuration ($APP_CODE)."
    return 1
  fi
  mkdir -p "$PELICAN_ETC"
  echo "$APP_RESP" | jq -r '.data // empty' > "$PELICAN_ETC/config.yml" 2>/dev/null
  if [ ! -s "$PELICAN_ETC/config.yml" ]; then
    log_err "Empty node configuration received."
    return 1
  fi
  chmod 600 "$PELICAN_ETC/config.yml"
  systemctl enable wings >/dev/null 2>&1 || true
  ensure_service wings 5 || log_err "Wings failed to start - check 'journalctl -u wings'."
  log "Wings connected to panel node $NODE_ID."
}

ensure_node() {
  panel_admin_exists || {
    if [ -f "$PI_ROOT/.node-waiting-flag" ]; then
      local age
      age=$(($(date +%s) - $(stat -c %Y "$PI_ROOT/.node-waiting-flag" 2>/dev/null || echo 0)))
      if [ "$age" -lt 3600 ]; then
        return 0
      fi
    fi
    touch "$PI_ROOT/.node-waiting-flag" 2>/dev/null || true
    log "Waiting for the panel admin account to be created at https://$PANEL_FQDN/installer - node will bootstrap automatically afterwards."
    return 0
  }
  rm -f "$PI_ROOT/.node-waiting-flag"

  if [ -f "$NODE_ATTEMPT_FILE" ]; then
    local age
    age=$(($(date +%s) - $(stat -c %Y "$NODE_ATTEMPT_FILE" 2>/dev/null || echo 0)))
    if [ "$age" -lt 600 ] && [ -f "$PELICAN_ETC/config.yml" ] && systemctl is-active --quiet wings; then
      return 0
    fi
  fi
  touch "$NODE_ATTEMPT_FILE" 2>/dev/null || true

  if [ -f "$PELICAN_ETC/config.yml" ] && systemctl is-active --quiet wings; then
    return 0
  fi

  ensure_app_api_key || return 1
  ensure_node_record || return 1
  ensure_node_allocations || return 1
  ensure_wings_config || return 1
}
