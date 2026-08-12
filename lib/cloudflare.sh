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

game_origin_ip() {
  local gw
  gw=$(docker network inspect pelican_nw --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
  [ -n "$gw" ] || gw=127.0.0.1
  echo "$gw"
}

public_ip() {
  local ip=""
  ip=$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(curl -fsS -m 10 https://ifconfig.me 2>/dev/null || true)
  echo "$ip"
}

cf_app_port_supported() {
  case "$1" in
    80|443|2052|2053|2082|2083|2086|2087|2095|2096|8080|8443) return 0 ;;
    *) return 1 ;;
  esac
}

cf_app_hostnames() {
  local port
  for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
    if cf_app_port_supported "$port"; then
      echo "app-$port.$DOMAIN"
    fi
  done
}

cf_config_content() {
  {
    echo "tunnel: $CF_TUNNEL_ID"
    echo "credentials-file: $CF_CREDS_FILE"
    echo "protocol: quic"
    echo "ingress:"
    echo "  - hostname: $PANEL_FQDN"
    echo "    service: https://127.0.0.1:8443"
    echo "    originRequest:"
    echo "      noTLSVerify: true"
    echo "  - hostname: $NODE_FQDN"
    echo "    service: http://127.0.0.1:8080"
    if [ "${CF_APP_ROUTING:-no}" = "yes" ]; then
      local port
      for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
        if cf_app_port_supported "$port"; then
          echo "  - hostname: app-$port.$DOMAIN"
          echo "    service: http://127.0.0.1:$port"
        fi
      done
    fi
    echo "  - service: http_status:404"
  } > "$1"
}

cf_dns_ensure() {
  local rtype=$1 name=$2 content=$3 proxied=$4 host existing
  host=$(echo "$name" | sed 's/[._]/\\&/g')
  cf_api GET "/zones/$CF_ZONE_ID/dns_records?type=$rtype&name=$name"
  existing=$(echo "$CF_RESP" | jq -r '.result[0].id // empty' 2>/dev/null)
  if [ -n "$existing" ]; then
    local cur
    cur=$(echo "$CF_RESP" | jq -r '.result[0].content // empty' 2>/dev/null)
    if [ "$cur" = "$content" ] && [ "$(echo "$CF_RESP" | jq -r '.result[0].proxied' 2>/dev/null)" = "$proxied" ]; then
      return 0
    fi
    log "Fixing DNS record $name..."
    cf_api PATCH "/zones/$CF_ZONE_ID/dns_records/$existing" "{\"type\":\"$rtype\",\"name\":\"$name\",\"content\":\"$content\",\"proxied\":$proxied}"
  else
    log "Creating DNS record $name..."
    cf_api POST "/zones/$CF_ZONE_ID/dns_records" "{\"type\":\"$rtype\",\"name\":\"$name\",\"content\":\"$content\",\"proxied\":$proxied}"
  fi
  cf_success || log_err "DNS update failed for $name: $CF_RESP"
}

cf_ensure_dns() {
  [ -n "$CF_TUNNEL_ID" ] || cf_ensure_tunnel || return 1
  [ -n "$CF_ZONE_ID" ] || cf_get_zone || return 1
  CF_ORIGIN_TARGET="$CF_TUNNEL_ID.cfargotunnel.com"

  cf_dns_ensure CNAME "$PANEL_FQDN" "$CF_ORIGIN_TARGET" true
  cf_dns_ensure CNAME "$NODE_FQDN" "$CF_ORIGIN_TARGET" true

  if [ "${CF_APP_ROUTING:-no}" = "yes" ]; then
    local app
    for app in $(cf_app_hostnames); do
      cf_dns_ensure CNAME "$app" "$CF_ORIGIN_TARGET" true
    done
  fi

  local pub port
  pub=$(public_ip)
  if [ -n "$pub" ]; then
    for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
      cf_dns_ensure A "$(game_fqdn "$port")" "$pub" false
    done
    cf_dns_ensure A "sftp.$DOMAIN" "$pub" false
  else
    log_err "Could not detect public IP - game hostnames not updated."
  fi
}

upnp_ensure() {
  command -v upnpc >/dev/null 2>&1 || apt-get install -y miniupnpc >>"$INSTALL_LOG" 2>&1 || return 0
  if ! upnpc -s 2>/dev/null | grep -qi "ExternalIPAddress"; then
    log "Router UPnP not available. Enable UPnP on the router or add manual port forwards:"
    log "  ${GAME_PORTS:-25565-25575} TCP+UDP and 2022 TCP -> $(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
    return 0
  fi
  local lan_ip first last
  lan_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  first=${GAME_PORTS%%-*}
  last=${GAME_PORTS##*-}
  upnpc -a "$lan_ip" "$first" "$last" TCP >>"$INSTALL_LOG" 2>&1 || true
  upnpc -a "$lan_ip" "$first" "$last" UDP >>"$INSTALL_LOG" 2>&1 || true
  upnpc -a "$lan_ip" 2022 2022 TCP >>"$INSTALL_LOG" 2>&1 || true
  log "UPnP port mappings ensured ($first-$last TCP/UDP + 2022)."
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
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$CF_BIN tunnel --config $CF_CFG_FILE run
Restart=always
RestartSec=5s

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
  cf_write_config || return 1
  cf_ensure_certs || return 1
  cf_ensure_service || return 1
  upnp_ensure
  return 0
}

ufw_setup() {
  log "Configuring firewall (SSH + game ports open, everything else tunneled)..."
  local ssh_port=22
  ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {gsub(/.*:/,"",$4); print $4; exit}')
  ssh_port=${ssh_port:-22}
  ufw allow "$ssh_port/tcp" >>"$INSTALL_LOG" 2>&1 || true
  ufw allow 22/tcp >>"$INSTALL_LOG" 2>&1 || true
  ufw allow "${GAME_PORTS:-25565-25575}/tcp" >>"$INSTALL_LOG" 2>&1 || true
  ufw allow "${GAME_PORTS:-25565-25575}/udp" >>"$INSTALL_LOG" 2>&1 || true
  ufw allow 2022/tcp >>"$INSTALL_LOG" 2>&1 || true
  if [ -n "${SSH_CONNECTION:-}" ]; then
    local client_ip
    client_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    if [ -n "$client_ip" ]; then
      ufw allow from "$client_ip" >>"$INSTALL_LOG" 2>&1 || true
    fi
  fi
  ufw default deny incoming >>"$INSTALL_LOG" 2>&1 || true
  ufw default allow outgoing >>"$INSTALL_LOG" 2>&1 || true
  ufw --force enable >>"$INSTALL_LOG" 2>&1 || true

  if ! ufw status verbose | grep -qE '^22/tcp|^'"$ssh_port"'/tcp'; then
    log_err "SSH allow rule missing after enabling the firewall - rolling back to avoid lockout!"
    ufw --force disable >>"$INSTALL_LOG" 2>&1 || true
    return 1
  fi
  log "Firewall active: SSH (port $ssh_port) + game ports ${GAME_PORTS:-25565-25575} + SFTP 2022."
}
