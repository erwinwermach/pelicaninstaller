PI_ROOT="${PI_ROOT:-/etc/pelican-installer}"
CONF_FILE="$PI_ROOT/installer.conf"
SECRETS_FILE="$PI_ROOT/secrets.env"
API_KEY_FILE="$PI_ROOT/api-key.env"
LOG_DIR="${LOG_DIR:-/var/log/pelican}"
INSTALL_LOG="$LOG_DIR/install.log"
PI_HOME="${PI_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PI_REPO_BASE="${PI_REPO_BASE:-https://github.com/erwinwermach/pelicaninstaller}"
PI_API_BASE="${PI_API_BASE:-https://api.github.com/repos/erwinwermach/pelicaninstaller}"
PI_REPO_TARBALL="$PI_REPO_BASE/archive/refs/heads/main.tar.gz"
PI_VERSION_URL="$PI_REPO_BASE/raw/main/VERSION"
PI_VERSION_API_URL="$PI_API_BASE/contents/VERSION"
CF_API_BASE=https://api.cloudflare.com/client/v4
CF_CFG_DIR="${CF_CFG_DIR:-/etc/cloudflared}"
CF_CFG_FILE="$CF_CFG_DIR/config.yml"
CF_CREDS_FILE="$CF_CFG_DIR/credentials.json"
CF_BIN="${CF_BIN:-/usr/local/bin/cloudflared}"
PANEL_DIR="${PANEL_DIR:-/var/www/pelican}"
PANEL_TLS_DIR="${PANEL_TLS_DIR:-/etc/pelican/tls}"
PANEL_STORAGE="${PANEL_STORAGE:-$PANEL_DIR/storage/app}"
ROUTES_STATE_FILE="$PANEL_STORAGE/routes.json"
PELICAN_ETC="${PELICAN_ETC:-/etc/pelican}"
WINGS_BIN="${WINGS_BIN:-/usr/local/bin/wings}"
BORE_BIN="${BORE_BIN:-/usr/local/bin/bore}"
FRPC_BIN="${FRPC_BIN:-/usr/local/bin/frpc}"
TUNNEL_NAME_PREFIX=pelican
LOCK_DIR="${LOCK_DIR:-/run/lock}"

set -a
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
set +a

if [ -n "${DOMAIN:-}" ]; then
  PANEL_FQDN="${PANEL_FQDN:-${PANEL_SUBDOMAIN:-panel}.$DOMAIN}"
  NODE_FQDN="${NODE_FQDN:-${NODE_SUBDOMAIN:-node}.$DOMAIN}"
else
  PANEL_FQDN="${PANEL_FQDN:-}"
  NODE_FQDN="${NODE_FQDN:-}"
fi

banner() {
  echo ""
  echo "======================================================"
  echo "  $*"
  echo "======================================================"
}

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "[$ts] $*" | tee -a "$INSTALL_LOG" 2>/dev/null || true
}

log_err() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "[$ts] ERROR: $*" | tee -a "$INSTALL_LOG" 2>/dev/null >&2 || true
}

die() {
  log_err "$*"
  echo ""
  echo "Installation failed. Logs: $INSTALL_LOG"
  echo "Fix the issue and re-run the installer - it resumes where it stopped."
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root." >&2
    exit 1
  fi
}

check_os() {
  local os_release="${OS_RELEASE_FILE:-/etc/os-release}"
  if [ ! -r "$os_release" ]; then
    die "Cannot detect OS. Ubuntu Server 24.04 or 26.04 required."
  fi
  # shellcheck disable=SC1090
  . "$os_release"
  if [ "$ID" != "ubuntu" ]; then
    die "This installer targets Ubuntu Server (found: ${PRETTY_NAME:-unknown})."
  fi
  case "$VERSION_ID" in
    24.*|26.*) ;;
    *)
      die "Unsupported Ubuntu version '$VERSION_ID'. Use 24.04 or 26.04 LTS."
      ;;
  esac
}

panel_php_version() {
  local v=""
  [ -f "$PI_ROOT/php.version" ] && v=$(cat "$PI_ROOT/php.version" 2>/dev/null | tr -d '[:space:]')
  echo "${v:-8.3}"
}

check_arch() {
  local arch
  arch=$(uname -m)
  if [ "$arch" != "x86_64" ] && [ "$arch" != "aarch64" ]; then
    die "Unsupported architecture: $arch"
  fi
}

check_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || true)
    case "$virt" in
      *openvz*|*lxc*) die "Virtualization '$virt' does not support Docker reliably. Use KVM/VMware/Xen or bare metal." ;;
    esac
  fi
}

random_hex() {
  openssl rand -hex "$1" 2>/dev/null || head -c "$(( $1 * 2 ))" /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-$(( $1 * 2 ))
}

tty_available() {
  [ -t 0 ] && return 0
  ( exec < /dev/tty ) 2>/dev/null && return 0
  return 1
}

tty_read() {
  local var=$1 label=$2 default=$3
  local val=""
  if tty_available; then
    if [ -t 0 ]; then
      read -r -p "$label" val
    else
      read -r -p "$label" val < /dev/tty
    fi
  else
    return 1
  fi
  val=${val:-$default}
  printf -v "$var" '%s' "$val"
}

tty_secret() {
  local var=$1 label=$2
  local val=""
  if tty_available; then
    if [ -t 0 ]; then
      read -r -s -p "$label" val
    else
      read -r -s -p "$label" val < /dev/tty
    fi
  else
    return 1
  fi
  echo "" >&2
  printf -v "$var" '%s' "$val"
}

wait_network() {
  local tries=${1:-30}
  local i
  for i in $(seq 1 "$tries"); do
    if curl -sS --connect-timeout 5 --max-time 8 -o /dev/null -w '%{http_code}' \
      https://api.cloudflare.com/client/v4/ 2>/dev/null | grep -qE '^[0-9]{3}$'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

expand_ports() {
  local spec=${1:-25565-25575}
  local token lo hi
  for token in ${spec//,/ }; do
    if [[ "$token" == *-* ]]; then
      lo=${token%-*}
      hi=${token#*-}
      seq "$lo" "$hi" 2>/dev/null
    else
      echo "$token"
    fi
  done
}

cf_api() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -X "$method" "$CF_API_BASE$path" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: pelican-installer")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  CF_RESP=""
  CF_CODE=000
  local try out
  for try in 1 2 3; do
    out=$(curl "${args[@]}" -m 30 -w $'\n%{http_code}' 2>/dev/null) || true
    if [ -n "$out" ]; then
      CF_CODE=${out##*$'\n'}
      CF_RESP=${out%$'\n'*}
      if [ "$CF_CODE" != "000" ]; then
        return 0
      fi
    fi
    sleep 3
  done
  return 1
}

cf_success() {
  case "$CF_CODE" in
    200|201|204) ;;
    *) return 1 ;;
  esac
  if [ -n "$CF_RESP" ]; then
    echo "$CF_RESP" | grep -q '"success":true' || return 1
  fi
  return 0
}

ensure_service() {
  local svc=$1
  local tries=${2:-3}
  local i
  systemctl enable "$svc" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$svc"; then
    return 0
  fi
  systemctl start "$svc" >/dev/null 2>&1 || true
  for i in $(seq 1 "$tries"); do
    if systemctl is-active --quiet "$svc"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

restart_service() {
  local svc=$1
  systemctl restart "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
}

deploy_template() {
  local src=$1 dst=$2 mode=$3
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  chmod "$mode" "$dst"
}

is_url() {
  [[ "$1" =~ ^https?:// ]]
}

normalize_domain() {
  local d=$1
  d=${d,,}
  d=${d#https://}
  d=${d#http://}
  d=${d#www.}
  d=${d%%/*}
  echo "$d"
}

valid_domain() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

pi_local_version() {
  local v=""
  [ -f "$PI_HOME/VERSION" ] && v=$(cat "$PI_HOME/VERSION" 2>/dev/null || true)
  echo "$v"
}

version_newer() {
  local a=$1 b=$2
  [ -n "$b" ] || return 0
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$a" gt "$b"
  else
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V 2>/dev/null | tail -1)" = "$a" ] && [ "$a" != "$b" ]
  fi
}

pi_fetch_update() {
  local tmp srcdir
  tmp=$(mktemp -d)
  if ! curl -fsSL -m 120 -o "$tmp/pi.tar.gz" "$PI_REPO_TARBALL"; then
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp/pi.tar.gz" -C "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  srcdir=$(find "$tmp" -maxdepth 2 -name 'VERSION' -printf '%h' -quit 2>/dev/null)
  if [ -z "$srcdir" ]; then
    rm -rf "$tmp"
    return 1
  fi
  cp -rf "$srcdir/." "$PI_HOME"/
  rm -rf "$tmp"
}

pi_remote_version() {
  local v=""
  v=$(curl -fsSL -m 20 "$PI_VERSION_API_URL" 2>/dev/null \
    | jq -r '.content // empty' 2>/dev/null \
    | tr -d '\n' | base64 -d 2>/dev/null || true)
  if [ -z "$v" ]; then
    v=$(curl -fsSL -m 20 "$PI_VERSION_URL" 2>/dev/null || true)
  fi
  echo "$v" | tr -d ' \t\r\n'
}

self_update() {
  if [ "$PI_HOME" != "/opt/pelican-installer" ] && [ "${PI_ALLOW_SELF_UPDATE:-0}" != "1" ]; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 0
  local remote_v local_v
  local_v=$(pi_local_version)
  remote_v=$(pi_remote_version)
  [ -n "$remote_v" ] || return 0
  version_newer "$remote_v" "$local_v" || return 0
  log "New installer version $remote_v available (local ${local_v:-none}) - updating..."
  if pi_fetch_update; then
    chmod +x "$PI_HOME"/bin/*.sh 2>/dev/null || true
    log "Installer updated to $remote_v."
    return 1
  fi
  log_err "Installer self-update failed - continuing with current version."
  return 0
}

fqdn_ok() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

arch_map() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) uname -m ;;
  esac
}

valid_game_ports() {
  local spec=${1:-} token lo hi
  [ -n "$spec" ] || return 1
  for token in ${spec//,/ }; do
    if [[ "$token" == *-* ]]; then
      lo=${token%-*}
      hi=${token#*-}
    else
      lo=$token
      hi=$token
    fi
    [[ "$lo" =~ ^[0-9]+$ ]] && [[ "$hi" =~ ^[0-9]+$ ]] || return 1
    [ "$lo" -ge 1 ] && [ "$hi" -le 65535 ] && [ "$lo" -le "$hi" ] || return 1
    if [ $(( hi - lo + 1 )) -gt 256 ]; then
      return 1
    fi
  done
  return 0
}

default_lan_cidr() {
  local src
  src=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
  [ -n "$src" ] || return 0
  echo "$(echo "$src" | cut -d. -f1-3).0/24"
}

is_cgnat_ip() {
  case "$1" in
    10.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[0-1].*|192.168.*|100.6[4-9].*|100.[7-9][0-9].*|100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}

wan_ip_is_usable() {
  local pub
  pub=$(public_ip)
  [ -n "$pub" ] || return 1
  ! is_cgnat_ip "$pub"
}

public_ip() {
  local ip=""
  ip=$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(curl -fsS -m 10 https://ifconfig.me 2>/dev/null || true)
  echo "$ip"
}

routes_state_write() {
  mkdir -p "$(dirname "$ROUTES_STATE_FILE")"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  chown www-data:www-data "$tmp" 2>/dev/null || true
  chmod 644 "$tmp"
  mv -f "$tmp" "$ROUTES_STATE_FILE"
}

panel_env_get() {
  local key=$1 val=""
  if [ -f "$PANEL_DIR/.env" ]; then
    val=$(grep -E "^${key}=" "$PANEL_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
  fi
  echo "$val"
}
