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
PELICAN_ETC="${PELICAN_ETC:-/etc/pelican}"
WINGS_BIN="${WINGS_BIN:-/usr/local/bin/wings}"
TUNNEL_NAME_PREFIX=pelican
LOCK_DIR="${LOCK_DIR:-/run/lock}"

set -a
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
set +a

banner() {
  echo ""
  echo "======================================================"
  echo "  $*"
  echo "======================================================"
}

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$INSTALL_LOG"
}

log_err() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] ERROR: $*" | tee -a "$INSTALL_LOG" >&2
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
    die "Cannot detect OS. Ubuntu Server 24.04 required."
  fi
  # shellcheck disable=SC1090
  . "$os_release"
  if [ "$ID" != "ubuntu" ] || [[ "$VERSION_ID" != 24.04* ]]; then
    die "This installer targets Ubuntu Server 24.04 (found: ${PRETTY_NAME:-unknown})."
  fi
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

tty_read() {
  local var=$1 label=$2 default=$3
  local val=""
  if [ -t 0 ]; then
    read -r -p "$label" val
  elif [ -e /dev/tty ]; then
    read -r -p "$label" val < /dev/tty
  else
    return 1
  fi
  val=${val:-$default}
  printf -v "$var" '%s' "$val"
}

tty_secret() {
  local var=$1 label=$2
  local val=""
  if [ -t 0 ]; then
    read -r -s -p "$label" val
  elif [ -e /dev/tty ]; then
    read -r -s -p "$label" val < /dev/tty
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
  [ "$CF_CODE" = "200" ] || [ "$CF_CODE" = "201" ] || [ "$CF_CODE" = "204" ]
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
