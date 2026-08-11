CF_TUNNEL_ID=""
CF_ZONE_ID=""
CF_ACCOUNT_ID=""
CF_ORIGIN_TARGET=""
GAME_FQDNS=""

game_fqdn() {
  echo "${GAME_SUBDOMAIN_PREFIX:-game}-$1.$DOMAIN"
}

cf_hostnames_list() {
  local out="$PANEL_FQDN $NODE_FQDN"
  local port
  for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
    out="$out $(game_fqdn "$port")"
  done
  echo "$out"
}

cf_tunnel_name() {
  echo "${TUNNEL_NAME_PREFIX}-${DOMAIN//./-}"
}

cf_install_binary() {
  if [ -x "$CF_BIN" ] && "$CF_BIN" --version >/dev/null 2>&1; then
    return 0
  fi
  log "Installing cloudflared..."
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
  esac
  curl -fsSL -m 120 -o "$CF_BIN" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" >>"$INSTALL_LOG" 2>&1 \
    || return 1
  chmod +x "$CF_BIN"
}

cf_verify_token() {
  cf_api GET /user/tokens/verify
  if cf_success && [ "$(echo "$CF_RESP" | jq -r '.result.status // empty' 2>/dev/null)" = "active" ]; then
    return 0
  fi
  log_err "Cloudflare API token rejected. Check it at https://dash.cloudflare.com/profile/api-tokens"
  return 1
}

cf_get_account() {
  if [ -n "${CF_ACCOUNT_ID:-}" ]; then
    return 0
  fi
  cf_api GET /accounts
  if cf_success; then
    CF_ACCOUNT_ID=$(echo "$CF_RESP" | jq -r '.result[0].id // empty' 2>/dev/null)
    if [ -n "$CF_ACCOUNT_ID" ]; then
      return 0
    fi
  fi
  log "Token cannot list accounts - deriving account id from zone lookup..."
  cf_get_zone || return 1
  CF_ACCOUNT_ID=$(echo "$CF_RESP" | jq -r '.result[0].account.id // empty' 2>/dev/null)
  if [ -n "$CF_ACCOUNT_ID" ]; then
    return 0
  fi
  log_err "Could not determine Cloudflare account id from token."
  log_err "Add CF_ACCOUNT_ID=<account id> to $CONF_FILE (see https://dash.cloudflare.com -> your profile -> Account ID)."
  return 1
}

cf_get_zone() {
  cf_api GET "/zones?name=$DOMAIN"
  if cf_success; then
    CF_ZONE_ID=$(echo "$CF_RESP" | jq -r '.result[0].id // empty' 2>/dev/null)
    if [ -n "$CF_ZONE_ID" ]; then
      return 0
    fi
  fi
  log_err "Domain '$DOMAIN' is not on your Cloudflare account. Add it first: https://dash.cloudflare.com"
  return 1
}

cf_ensure_tunnel() {
  cf_verify_token || return 1
  cf_get_account || return 1

  local name
  name=$(cf_tunnel_name)

  if [ -f "$CF_CREDS_FILE" ]; then
    CF_TUNNEL_ID=$(jq -r '.TunnelID // empty' "$CF_CREDS_FILE" 2>/dev/null)
    if [ -n "$CF_TUNNEL_ID" ]; then
      cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID"
      if cf_success; then
        log "Using existing tunnel $CF_TUNNEL_ID"
        return 0
      fi
      log_err "Stored tunnel no longer exists - recreating."
    fi
  fi

  log "Creating Cloudflare tunnel '$name'..."
  cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "{\"name\":\"$name\"}"
  if ! cf_success; then
    if echo "$CF_RESP" | grep -q '1013'; then
      log "Tunnel name already exists (orphaned from a previous attempt) - removing it and retrying..."
      cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=$name"
      local existing_id
      existing_id=$(echo "$CF_RESP" | jq -r --arg n "$name" '.result[]? | select(.name == $n) | .id // empty' 2>/dev/null)
      [ -n "$existing_id" ] && cf_api DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$existing_id"
      cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "{\"name\":\"$name\"}"
    fi
    if ! cf_success; then
      log_err "Tunnel creation failed: $CF_RESP"
      return 1
    fi
  fi
  CF_TUNNEL_ID=$(echo "$CF_RESP" | jq -r '.result.id // empty' 2>/dev/null)

  local secret account_tag tok decoded
  secret=$(echo "$CF_RESP" | jq -r '.result.credentials_file.TunnelSecret // empty' 2>/dev/null)
  account_tag=$(echo "$CF_RESP" | jq -r '.result.credentials_file.AccountTag // empty' 2>/dev/null)
  [ -n "$account_tag" ] || account_tag=$CF_ACCOUNT_ID

  if [ -z "$secret" ]; then
    log "Extracting tunnel secret from tunnel token..."
    secret=$(echo "$CF_RESP" | jq -r '.result.token // empty' 2>/dev/null | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.s // empty' 2>/dev/null)
  fi

  if [ -z "$secret" ]; then
    log "Requesting tunnel token..."
    cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/token"
    if cf_success; then
      tok=$(echo "$CF_RESP" | jq -r '.result.token // empty' 2>/dev/null)
      if [ -n "$tok" ]; then
        decoded=$(echo "$tok" | tr '_-' '/+' | base64 -d 2>/dev/null || true)
        secret=$(echo "$decoded" | jq -r '.s // empty' 2>/dev/null)
        account_tag=$(echo "$decoded" | jq -r '.a // empty' 2>/dev/null)
      fi
    fi
  fi

  if [ -z "$CF_TUNNEL_ID" ] || [ -z "$secret" ]; then
    log_err "Could not obtain tunnel credentials. Create the tunnel manually at https://one.dash.cloudflare.com and run the installer again."
    return 1
  fi

  mkdir -p "$CF_CFG_DIR"
  cat > "$CF_CREDS_FILE" <<EOF
{"AccountTag":"$account_tag","TunnelID":"$CF_TUNNEL_ID","TunnelSecret":"$secret"}
EOF
  chmod 600 "$CF_CREDS_FILE"
  log "Tunnel created: $CF_TUNNEL_ID"
}

cf_ensure_dns() {
  [ -n "$CF_TUNNEL_ID" ] || cf_ensure_tunnel || return 1
  [ -n "$CF_ZONE_ID" ] || cf_get_zone || return 1
  CF_ORIGIN_TARGET="$CF_TUNNEL_ID.cfargotunnel.com"

  local host
  for host in $(cf_hostnames_list); do
    cf_api GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$host"
    local existing content
    existing=$(echo "$CF_RESP" | jq -r '.result[0].id // empty' 2>/dev/null)
    content=$(echo "$CF_RESP" | jq -r '.result[0].content // empty' 2>/dev/null)
    if [ -n "$existing" ] && [ "$content" = "$CF_ORIGIN_TARGET" ]; then
      continue
    fi
    if [ -n "$existing" ]; then
      log "Fixing DNS record $host (was $content)..."
      cf_api PATCH "/zones/$CF_ZONE_ID/dns_records/$existing" "{\"content\":\"$CF_ORIGIN_TARGET\",\"proxied\":true}"
    else
      log "Creating DNS record $host..."
      cf_api POST "/zones/$CF_ZONE_ID/dns_records" "{\"type\":\"CNAME\",\"name\":\"$host\",\"content\":\"$CF_ORIGIN_TARGET\",\"proxied\":true}"
    fi
    if ! cf_success; then
      log_err "DNS update failed for $host: $CF_RESP"
    fi
  done
}

cf_ensure_routes() {
  [ -n "$CF_TUNNEL_ID" ] || cf_ensure_tunnel || return 1
  local port host service_type result

  for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
    host=$(game_fqdn "$port")
    for service_type in tcp udp; do
      if cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/routes" 2>/dev/null; then
        result=$(echo "$CF_RESP" | jq -r --arg h "$host" --arg t "$service_type" '.result[] | select(.hostname == $h and .type == $t) | .id // empty' 2>/dev/null)
      else
        result=""
      fi
      if [ -n "$result" ]; then
        continue
      fi
      log "Creating $service_type tunnel route for $host..."
      cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/routes" \
        "{\"hostname\":\"$host\",\"type\":\"$service_type\",\"service\":\"$service_type://127.0.0.1:$port\"}"
      if ! cf_success; then
        log_err "Route creation failed for $host ($service_type): $CF_RESP"
      fi
    done
  done

  host="$NODE_FQDN"
  cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/routes" 2>/dev/null
  if ! echo "$CF_RESP" | jq -e --arg h "$host:2022" '.result[] | select(.hostname == $h and .type == "tcp")' >/dev/null 2>&1; then
    log "Creating TCP tunnel route for SFTP ($host:2022)..."
    cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/routes" \
      "{\"hostname\":\"$host:2022\",\"type\":\"tcp\",\"service\":\"tcp://127.0.0.1:2022\"}"
    if ! cf_success; then
      log_err "SFTP route creation failed: $CF_RESP"
    fi
  fi
}

cf_config_content() {
  {
    echo "tunnel: $CF_TUNNEL_ID"
    echo "credentials-file: $CF_CREDS_FILE"
    echo "protocol: quic"
    echo "ingress:"
    echo "  - hostname: $PANEL_FQDN"
    echo "    service: https://127.0.0.1:8443"
    echo "  - hostname: $NODE_FQDN"
    echo "    service: http://127.0.0.1:8080"
    local port
    for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
      echo "  - hostname: $(game_fqdn "$port")"
      echo "    service: tcp://127.0.0.1:$port"
      echo "  - hostname: $(game_fqdn "$port")"
      echo "    service: udp://127.0.0.1:$port"
    done
    echo "  - service: http_status:404"
  } > "$1"
}

cf_write_config() {
  [ -n "$CF_TUNNEL_ID" ] || cf_ensure_tunnel || return 1
  mkdir -p "$CF_CFG_DIR"
  local tmp
  tmp=$(mktemp)
  cf_config_content "$tmp"
  if ! cmp -s "$tmp" "$CF_CFG_FILE"; then
    cp -f "$tmp" "$CF_CFG_FILE"
    chmod 600 "$CF_CFG_FILE"
    log "Tunnel config updated."
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
      restart_service cloudflared
    fi
  fi
  rm -f "$tmp"
}

cf_cert_expiring() {
  local cert=$1
  [ -f "$cert" ] || return 0
  local end
  end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)
  local end_epoch now_epoch diff
  end_epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  diff=$(( end_epoch - now_epoch ))
  if [ "$diff" -lt 1209600 ]; then
    return 0
  fi
  return 1
}

cf_ensure_certs() {
  local cert_dir="$PANEL_TLS_DIR/panel"
  local cert="$cert_dir/fullchain.pem"
  local key="$cert_dir/privkey.pem"

  if [ -f "$cert" ] && [ -f "$key" ] && ! cf_cert_expiring "$cert"; then
    if openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -q "$PANEL_FQDN"; then
      return 0
    fi
  fi

  mkdir -p "$cert_dir"
  local key_file csr_file csr body
  key_file=$(mktemp)
  csr_file=$(mktemp)
  openssl req -new -newkey rsa:2048 -nodes -keyout "$key_file" -out "$csr_file" \
    -subj "//CN=$PANEL_FQDN" -addext "subjectAltName=DNS:$PANEL_FQDN" 2>/dev/null || {
    rm -f "$key_file" "$csr_file"
    log_err "Could not generate certificate key pair."
    return 1
  }
  csr=$(cat "$csr_file")
  body=$(jq -nc --arg h "$PANEL_FQDN" --arg csr "$csr" \
    '{hostnames: [$h], request_type: "origin-rsa", requested_validity: 5475, csr: $csr}')

  cf_api POST /certificates "$body"
  if ! cf_success; then
    rm -f "$key_file" "$csr_file"
    log_err "Origin CA certificate issuance failed: $CF_RESP"
    log_err "Ensure your API token has 'SSL and Certificates > Edit' permission."
    return 1
  fi

  echo "$CF_RESP" | jq -r '.result.certificate // empty' > "$cert" 2>/dev/null
  cp -f "$key_file" "$key"
  rm -f "$key_file" "$csr_file"
  chmod 644 "$cert"
  chmod 600 "$key"
  log "Origin CA certificate issued for $PANEL_FQDN."
}

cf_ensure_service() {
  cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel Agent (Pelican)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CF_BIN tunnel --config $CF_CFG_FILE run
Restart=always
RestartSec=5s
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ensure_service cloudflared 5
}

cf_full_ensure() {
  cf_install_binary || { log_err "Failed to install cloudflared."; return 1; }
  cf_verify_token || return 1
  cf_get_account || return 1
  cf_get_zone || return 1
  cf_ensure_tunnel || return 1
  cf_ensure_dns || return 1
  cf_ensure_routes
  cf_write_config || return 1
  cf_ensure_certs || return 1
  cf_ensure_service || return 1
  return 0
}

ufw_setup() {
  log "Configuring firewall (only SSH open - everything else via tunnel)..."
  local ssh_port=22
  ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {gsub(/.*:/,"",$4); print $4; exit}')
  ssh_port=${ssh_port:-22}
  ufw --force allow "$ssh_port/tcp" >>"$INSTALL_LOG" 2>&1 || true
  ufw default deny incoming >>"$INSTALL_LOG" 2>&1 || true
  ufw default allow outgoing >>"$INSTALL_LOG" 2>&1 || true
  ufw --force enable >>"$INSTALL_LOG" 2>&1 || true
}
