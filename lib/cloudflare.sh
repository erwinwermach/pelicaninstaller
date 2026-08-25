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
  curl -fsSL -m 120 -o "$CF_BIN" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(arch_map)" >>"$INSTALL_LOG" 2>&1 \
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

cf_tunnel_list_json() {
  cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?is_deleted=false&per_page=20"
  if ! cf_success; then
    log_err "Could not list tunnels: $CF_RESP"
    return 1
  fi
  echo "$CF_RESP" | jq -c --arg p "$TUNNEL_NAME_PREFIX-" \
    '[.result[]? | select((.name // "") | startswith($p)) | {id, name, status, connections: ((.connections // []) | length)}]' 2>/dev/null
}

cf_fetch_tunnel_token() {
  local id=$1 tok decoded
  cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id/token"
  if ! cf_success; then
    return 1
  fi
  tok=$(echo "$CF_RESP" | jq -r '.result.token // empty' 2>/dev/null)
  [ -n "$tok" ] || return 1
  decoded=$(echo "$tok" | tr '_-' '/+' | base64 -d 2>/dev/null || true)
  CF_TUNNEL_ID=$id
  CF_TUNNEL_SECRET=$(echo "$decoded" | jq -r '.s // empty' 2>/dev/null)
  CF_ACCOUNT_TAG=$(echo "$decoded" | jq -r '.a // empty' 2>/dev/null)
  [ -n "$CF_TUNNEL_SECRET" ] || return 1
  return 0
}

cf_write_creds_file() {
  mkdir -p "$CF_CFG_DIR"
  printf '{"AccountTag":"%s","TunnelID":"%s","TunnelSecret":"%s"}\n' \
    "${CF_ACCOUNT_TAG:-$CF_ACCOUNT_ID}" "$CF_TUNNEL_ID" "$CF_TUNNEL_SECRET" > "$CF_CREDS_FILE"
  chmod 600 "$CF_CREDS_FILE"
}

cf_delete_managed_dns() {
  local tid=$1 extra_a=$2 rec name content
  cf_api GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&per_page=100"
  if cf_success; then
    for rec in $(echo "$CF_RESP" | jq -r --arg t "$tid.cfargotunnel.com" \
      '.result[]? | select(.content == $t) | .id' 2>/dev/null); do
      cf_api DELETE "/zones/$CF_ZONE_ID/dns_records/$rec"
      cf_success && log "Removed stale CNAME record ($rec)." || log_err "Could not remove DNS record $rec."
    done
  fi
  if [ "$extra_a" = "yes" ]; then
    local pub suffix
    pub=$(public_ip)
    [ -n "$pub" ] || return 0
    suffix=".$DOMAIN"
    cf_api GET "/zones/$CF_ZONE_ID/dns_records?type=A&per_page=200"
    if cf_success; then
      while IFS=$'\t' read -r rec name content; do
        [ -n "$rec" ] || continue
        case "$name" in
          "game-"*"$suffix") ;;
          "sftp$suffix") ;;
          *) continue ;;
        esac
        [ "$content" = "$pub" ] || continue
        cf_api DELETE "/zones/$CF_ZONE_ID/dns_records/$rec"
        cf_success && log "Removed managed A record $name." || log_err "Could not remove A record $name."
      done <<EOF
$(echo "$CF_RESP" | jq -r '.result[]? | [.id, .name, (.content // "")] | @tsv' 2>/dev/null)
EOF
    fi
  fi
}

cf_ask_policy() {
  local val=""
  echo ""
  echo "====================================================================" >&2
  echo "  EXISTING CLOUDFLARE TUNNEL FOUND" >&2
  echo "====================================================================" >&2
  echo "" >&2
  echo "  A tunnel named '$(cf_tunnel_name)' already exists on this account." >&2
  echo "  This happens when this machine (or another one on the same domain)" >&2
  echo "  was installed before. Cloudflare tunnels carry your panel + node" >&2
  echo "  hostnames, so you have to decide what to do with the old one:" >&2
  echo "" >&2
  echo "$CF_EXISTING_LIST" | jq -r --arg n "$(cf_tunnel_name)" \
    '.[] | select(.name == $n) | "  Tunnel:  \(.name)" + "\n  Status:  \(.status)  ·  connectors: \(.connections)  ·  id: \(.id)"' >&2 2>/dev/null
  echo "" >&2
  echo "  R = USE IT, but update it for THIS machine (recommended)" >&2
  echo "      Keeps the existing tunnel id and its DNS records, but re-registers" >&2
  echo "      this server as the connector and refreshes credentials, ingress" >&2
  echo "      config and certificates with this machine's details. No downtime" >&2
  echo "      on the DNS side. Pick this when the old tunnel was just an" >&2
  echo "      earlier install of this same server." >&2
  echo "" >&2
  echo "  F = DELETE it and make a brand-new tunnel" >&2
  echo "      Removes the old tunnel + its DNS records, then creates a fresh" >&2
  echo "      tunnel + records from scratch. Brief outage while DNS/certs are" >&2
  echo "      recreated. Pick this if the old tunnel belongs to a different" >&2
  echo "      server you are taking over from." >&2
  echo "" >&2
  echo "  W = DELETE it, remake it, and clean up everything managed" >&2
  echo "      Same as F, but also removes game/SFTP A records the installer" >&2
  echo "      created before. Full reset of all Cloudflare-managed resources." >&2
  echo "" >&2
  echo "  A = ABORT" >&2
  echo "      Stop the installer so you can review/clean up manually." >&2
  echo "      Nothing is changed; re-run the installer after you decide." >&2
  echo "" >&2
  echo "  (Tip: 'connectors' = how many servers are currently running this" >&2
  echo "   tunnel. 0 means the old server is offline - safe to reuse or delete.)" >&2
  echo "" >&2
  while :; do
    tty_read CF_POLICY_CHOICE "What should I do? [R/F/W/A] (default R): " "R"
    case "${CF_POLICY_CHOICE,,}" in
      r|reuse|use|update) echo reuse; return 0 ;;
      f|replace|delete|remake|fresh) echo replace; return 0 ;;
      w|wipe|clean|cleanup) echo clean; return 0 ;;
      a|abort|stop|cancel) echo abort; return 0 ;;
    esac
    echo "  Please answer R, F, W or A." >&2
  done
}

cf_existing_decision() {
  CF_EXISTING_LIST=$(cf_tunnel_list_json) || return 1
  if [ "$CF_EXISTING_LIST" = "[]" ]; then
    return 0
  fi

  local desired_name
  desired_name=$(cf_tunnel_name)

  # Only a tunnel with OUR exact name matters. Other pelican-* tunnels are
  # unrelated installs (e.g. a different server on the same account) - never touch them.
  local ours
  ours=$(echo "$CF_EXISTING_LIST" | jq -c --arg n "$desired_name" \
    '[.[] | select(.name == $n)][0] // empty' 2>/dev/null)
  if [ -z "$ours" ]; then
    log "Existing tunnels do not include '$desired_name' - leaving them untouched."
    return 0
  fi

  local our_id our_conns
  our_id=$(echo "$ours" | jq -r '.id // empty' 2>/dev/null)
  our_conns=$(echo "$ours" | jq -r '.connections // 0' 2>/dev/null)

  if [ -n "$our_id" ] && [ -n "${CF_TUNNEL_ID:-}" ] && [ "$CF_TUNNEL_ID" = "$our_id" ]; then
    log "Stored tunnel $our_id still exists and matches - reusing it."
    return 0
  fi
  if [ -f "$CF_CREDS_FILE" ]; then
    log "Stored credentials reference a different/deleted tunnel - ignoring them."
  fi

  local policy=${CF_EXISTING:-} action
  if [ -z "$policy" ]; then
    if [ "${our_conns:-0}" -eq 0 ]; then
      policy=replace
      log "Tunnel '$desired_name' exists but has NO active connectors (old server offline) - deleting it and creating a fresh tunnel for this machine."
    elif tty_available; then
      action=$(cf_ask_policy)
    else
      policy=reuse
      log "Non-interactive run and tunnel '$desired_name' is still live - defaulting to reuse (it will be updated with this machine's connector)."
    fi
  else
    action=$policy
  fi
  action=${action:-$policy}

  case "$action" in
    reuse)
      log "Reusing tunnel $our_id and updating it for this machine (new connector + credentials)..."
      if cf_fetch_tunnel_token "$our_id"; then
        cf_write_creds_file
        log "Tunnel re-registered: $CF_TUNNEL_ID (credentials + config will be refreshed for this server)."
        return 0
      fi
      log_err "Could not obtain credentials for tunnel $our_id (deleted mid-run or token lacks Tunnel Edit)."
      return 1
      ;;
    replace|clean)
      log "Deleting old tunnel $our_id..."
      cf_api DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$our_id"
      if ! cf_success; then
        log "Delete failed - retrying with cascade cleanup..."
        cf_api DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$our_id?cascade=true"
      fi
      cf_success || log_err "Tunnel $our_id could not be removed (active connector elsewhere?). Continuing."
      cf_delete_managed_dns "$our_id" no
      if [ "$action" = "clean" ]; then
        cf_delete_managed_dns "$our_id" yes
      fi
      CF_TUNNEL_ID=""
      rm -f "$CF_CREDS_FILE" "$CF_CFG_FILE"
      return 0
      ;;
    abort)
      log_err "Aborted by user - clean up at https://one.dash.cloudflare.com and re-run."
      return 1
      ;;
    *)
      log_err "Invalid CF_EXISTING value '$action' (use reuse|replace|clean)."
      return 1
      ;;
  esac
}

cf_ensure_tunnel() {
  cf_verify_token || return 1
  cf_get_account || return 1

  if [ -f "$CF_CREDS_FILE" ]; then
    CF_TUNNEL_ID=$(jq -r '.TunnelID // empty' "$CF_CREDS_FILE" 2>/dev/null)
    if [ -n "$CF_TUNNEL_ID" ]; then
      cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID"
      if cf_success && [ "$(echo "$CF_RESP" | jq -r '.result.deleted_at // empty' 2>/dev/null)" = "" ]; then
        log "Using existing tunnel $CF_TUNNEL_ID"
        return 0
      fi
    fi
  fi

  cf_existing_decision || return 1

  local name
  name=$(cf_tunnel_name)

  log "Creating Cloudflare tunnel '$name'..."
  cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "{\"name\":\"$name\"}"
  if ! cf_success; then
    if echo "$CF_RESP" | grep -q 'max_tunnels\|quota'; then
      log_err "Tunnel quota exhausted: $CF_RESP"
      return 1
    fi
    log "Retrying after conflict cleanup..."
    cf_existing_decision || return 1
    cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "{\"name\":\"$name\"}"
  fi
  if ! cf_success; then
    log_err "Tunnel creation failed: $CF_RESP"
    return 1
  fi
  CF_TUNNEL_ID=$(echo "$CF_RESP" | jq -r '.result.id // empty' 2>/dev/null)

  local secret account_tag
  secret=$(echo "$CF_RESP" | jq -r '.result.credentials_file.TunnelSecret // empty' 2>/dev/null)
  account_tag=$(echo "$CF_RESP" | jq -r '.result.credentials_file.AccountTag // empty' 2>/dev/null)

  if [ -z "$secret" ] || [ -z "$CF_TUNNEL_ID" ]; then
    if ! cf_fetch_tunnel_token "$CF_TUNNEL_ID"; then
      log_err "Could not obtain tunnel credentials. Create the tunnel manually at https://one.dash.cloudflare.com and run the installer again."
      return 1
    fi
  else
    CF_TUNNEL_SECRET=$secret
    CF_ACCOUNT_TAG=$account_tag
  fi

  cf_write_creds_file
  log "Tunnel created: $CF_TUNNEL_ID"
}

game_origin_ip() {
  local gw
  gw=$(docker network inspect pelican_nw --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
  [ -n "$gw" ] || gw=127.0.0.1
  echo "$gw"
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

cgnat_notice_once() {
  local marker="$PI_ROOT/.cgnat-notice"
  [ -f "$marker" ] && return 0
  {
    echo "Public IP is behind CGNAT (shared carrier address) - direct A records for"
    echo "game hostnames would be unreachable and were NOT created."
    echo "Players connect via the configured GAME_ROUTING backend instead"
    echo "(playit.gg by default). SFTP stays reachable over LAN or a VPS tunnel."
  } | tee -a "$INSTALL_LOG" 2>/dev/null >&2 || true
  mkdir -p "$PI_ROOT"
  touch "$marker"
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

  if wan_ip_is_usable; then
    rm -f "$PI_ROOT/.cgnat-notice"
    local pub port
    pub=$(public_ip)
    for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
      cf_dns_ensure A "$(game_fqdn "$port")" "$pub" false
    done
    cf_dns_ensure A "sftp.$DOMAIN" "$pub" false
  else
    cgnat_notice_once
  fi
}

upnp_ensure() {
  command -v upnpc >/dev/null 2>&1 || apt-get install -y miniupnpc >>"$INSTALL_LOG" 2>&1 || return 0
  local ext
  ext=$(upnpc -s 2>/dev/null | awk '/ExternalIPAddress/ {print $3}')
  if [ -z "$ext" ]; then
    log "Router UPnP not available. Enable UPnP on the router or add manual port forwards:"
    log "  ${GAME_PORTS:-25565-25575} TCP+UDP and 2022 TCP -> $(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
    return 0
  fi
  if is_cgnat_ip "$ext"; then
    log "Router WAN $ext is carrier-grade NAT - port mappings would not receive inbound traffic; skipping."
    log "Game connectivity comes from the routing backend (see GAME_ROUTING in $CONF_FILE)."
    return 0
  fi
  local lan_ip port count=0 total=0
  lan_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  for port in $(expand_ports "${GAME_PORTS:-25565-25575}"); do
    total=$((total + 2))
    upnpc -a "$lan_ip" "$port" "$port" TCP >>"$INSTALL_LOG" 2>&1 && count=$((count + 1))
    upnpc -a "$lan_ip" "$port" "$port" UDP >>"$INSTALL_LOG" 2>&1 && count=$((count + 1))
  done
  total=$((total + 1))
  upnpc -a "$lan_ip" 2022 2022 TCP >>"$INSTALL_LOG" 2>&1 && count=$((count + 1))
  log "UPnP port mappings ensured ($count/$total): ${GAME_PORTS:-25565-25575} TCP+UDP per port + 2022."
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

cf_light_ensure() {
  if ! systemctl is-active --quiet cloudflared 2>/dev/null; then
    [ -f "$CF_CREDS_FILE" ] && [ -f "$CF_CFG_FILE" ] && cf_install_binary && cf_ensure_service || return 1
    return 0
  fi
  local tmp ok=0
  tmp=$(mktemp)
  if cf_config_content "$tmp" && cmp -s "$tmp" "$CF_CFG_FILE"; then
    ok=1
  fi
  rm -f "$tmp"
  if [ "$ok" != "1" ]; then
    cf_write_config || return 1
    restart_service cloudflared
  fi
  if cf_cert_expiring "$PANEL_TLS_DIR/panel/fullchain.pem"; then
    cf_ensure_certs || return 1
    restart_service nginx
  fi
  return 0
}

cf_deep_due() {
  local marker="$PI_ROOT/.cf-deep-last"
  local interval=${CF_DEEP_INTERVAL:-1800}
  local now last age
  now=$(date +%s)
  last=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
  age=$(( now - last ))
  [ "$age" -ge "$interval" ]
}

cf_deep_mark() {
  mkdir -p "$PI_ROOT"
  touch "$PI_ROOT/.cf-deep-last"
}

ufw_setup() {
  log "Configuring firewall (SSH + game ports open, everything else tunneled)..."
  local ssh_port=22
  ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {gsub(/.*:/,"",$4); print $4; exit}')
  ssh_port=${ssh_port:-22}
  ufw allow "$ssh_port/tcp" >>"$INSTALL_LOG" 2>&1 || true
  ufw allow 22/tcp >>"$INSTALL_LOG" 2>&1 || true
  local port_token
  for port_token in $(ufw_port_tokens "${GAME_PORTS:-}"); do
    ufw allow "${port_token}/tcp" >>"$INSTALL_LOG" 2>&1 || true
    ufw allow "${port_token}/udp" >>"$INSTALL_LOG" 2>&1 || true
  done
  ufw allow 2022/tcp >>"$INSTALL_LOG" 2>&1 || true
  if [ -n "${SSH_CONNECTION:-}" ]; then
    local client_ip
    client_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    if [ -n "$client_ip" ]; then
      ufw allow from "$client_ip" >>"$INSTALL_LOG" 2>&1 || true
    fi
  fi
  local lan_cidr="${LAN_ALLOW:-$(default_lan_cidr)}"
  if [ -n "$lan_cidr" ]; then
    ufw allow in from "$lan_cidr" comment 'LAN' >>"$INSTALL_LOG" 2>&1 || \
      ufw allow in from "$lan_cidr" >>"$INSTALL_LOG" 2>&1 || true
    log "LAN rule active for $lan_cidr (router discovery, local panel access)."
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
