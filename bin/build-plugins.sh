#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"

command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 1; }

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.zip

for plugin_dir in "$SCRIPT_DIR"/plugins/*/; do
  name=$(basename "$plugin_dir")
  [ -f "$plugin_dir/plugin.json" ] || continue
  (cd "$SCRIPT_DIR/plugins" && zip -qr "$DIST_DIR/$name.zip" "$name")
  echo "built dist/$name.zip"
done
