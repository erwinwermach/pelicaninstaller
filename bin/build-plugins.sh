#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
# Feed consumed by the panel's plugin updater (plugin.json update_url).
RELEASE_BASE="${PI_RELEASE_BASE:-https://github.com/erwinwermach/pelicaninstaller/releases/latest/download}"

zip_dir() {
  local name=$1
  if command -v zip >/dev/null 2>&1; then
    (cd "$SCRIPT_DIR/plugins" && zip -qr "$DIST_DIR/$name.zip" "$name")
  else
    python3 - "$SCRIPT_DIR/plugins" "$name" "$DIST_DIR/$name.zip" <<'PY'
import os, sys, zipfile
root, name, dest = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, name)):
        dirnames.sort()
        filenames.sort()
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            z.write(full, os.path.relpath(full, root))
PY
  fi
}

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.zip "$DIST_DIR/plugins-feed.json"

feed="{}"
for plugin_dir in "$SCRIPT_DIR"/plugins/*/; do
  name=$(basename "$plugin_dir")
  [ -f "$plugin_dir/plugin.json" ] || continue
  zip_dir "$name"
  echo "built dist/$name.zip"
  version=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$plugin_dir/plugin.json" 2>/dev/null || true)
  if [ -n "$version" ]; then
    feed=$(printf '%s' "$feed" | python3 -c '
import json, sys
feed = json.load(sys.stdin)
print(json.dumps({**feed, sys.argv[1]: {
    "version": sys.argv[2],
    "download_url": sys.argv[3] + "/" + sys.argv[1] + ".zip",
}}, indent=2))
' "$name" "$version" "$RELEASE_BASE")
  fi
done

printf '%s\n' "$feed" > "$DIST_DIR/plugins-feed.json"
python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$DIST_DIR/plugins-feed.json" \
  || { echo "invalid plugins-feed.json generated" >&2; exit 1; }
echo "built dist/plugins-feed.json"
