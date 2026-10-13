#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${PELICAN_REPO_URL:-https://github.com/erwinwermach/pelicaninstaller/archive/refs/heads/main.tar.gz}"
VERSION_URL="${PELICAN_VERSION_URL:-${REPO_URL%/archive/refs/heads/*}/raw/main/VERSION}"

DST=/opt/pelican-installer

# Run the installed copy only when it matches the published version. A stale
# copy can be broken in ways that prevent its own self-update (e.g. an
# installer.conf that the old code cannot load), so a fresh bootstrap must be
# able to replace it. Network failure falls back to the installed copy.
if [ -x "$DST/installer.sh" ] && bash -n "$DST/installer.sh" 2>/dev/null; then
  local_v=$(tr -d ' \t\r\n' < "$DST/VERSION" 2>/dev/null || true)
  remote_v=$(curl -fsSL -m 20 "$VERSION_URL" 2>/dev/null | tr -d ' \t\r\n' || true)
  if [ -n "$remote_v" ] && [ "$remote_v" != "$local_v" ]; then
    echo "Installer at $DST is ${local_v:-unknown}, latest is $remote_v - refreshing..."
  else
    exec bash "$DST/installer.sh" "$@"
  fi
fi

# Serialize concurrent bootstraps so two runs cannot interleave the download.
if command -v flock >/dev/null 2>&1 && mkdir -p /run/lock 2>/dev/null; then
  exec 7>/run/lock/pelican-bootstrap.lock
  flock -n 7 || { echo "Another installer bootstrap is already running." >&2; exit 1; }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading pelican-installer..."
curl -fsSL "$REPO_URL" -o "$TMP/repo.tar.gz" || {
  echo "Download failed: $REPO_URL" >&2
  echo "If this repository was moved, export the new URL: PELICAN_REPO_URL=https://github.com/user/repo/archive/refs/heads/main.tar.gz" >&2
  exit 1
}

mkdir -p "$DST"
tar -xzf "$TMP/repo.tar.gz" -C "$TMP"
SRCDIR=$(find "$TMP" -maxdepth 2 -name 'installer.sh' -printf '%h' -quit 2>/dev/null || find "$TMP" -maxdepth 2 -name 'installer.sh' | head -1 | xargs dirname)
[ -n "$SRCDIR" ] || { echo "Invalid repository archive (installer.sh not found)." >&2; exit 1; }

cp -rf "$SRCDIR"/. "$DST"/
chmod +x "$DST"/bin/*.sh 2>/dev/null || true

echo "Installer ready at $DST"
exec bash "$DST/installer.sh" "$@"
