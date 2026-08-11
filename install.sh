#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${PELICAN_REPO_URL:-https://github.com/erwinwermach/pelicaninstaller/archive/refs/heads/main.tar.gz}"

DST=/opt/pelican-installer
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
