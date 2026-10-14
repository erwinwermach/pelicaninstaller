PANEL_PLUGINS=${PANEL_PLUGINS:-minimal}
INSTALL_SELF_PLUGINS=${INSTALL_SELF_PLUGINS:-yes}

SELF_PLUGIN_RELEASE_BASE="${SELF_PLUGIN_RELEASE_BASE:-https://github.com/erwinwermach/pelicaninstaller/releases/latest/download}"

plugin_catalog() {
  # Pinned hub release ids are only a fallback: at import time the installer
  # resolves the hub's newest release per plugin (plugin_hub_latest_url).
  cat <<'EOF'
modpack-manager|https://hub.pelican.dev/plugins/modpack-manager/download/248/modpack-manager.zip
minecraft-modrinth|https://hub.pelican.dev/plugins/minecraft-modrinth/download/167/minecraft-modrinth.zip
player-counter|https://hub.pelican.dev/plugins/player-counter/download/168/player-counter.zip
system-status-monitor|https://hub.pelican.dev/plugins/system-status-monitor/download/102/system-status-monitor.zip
mclogs-uploader|https://hub.pelican.dev/plugins/mclogs-uploader/download/149/mclogs-uploader.zip
EOF
}

plugin_hub_latest_url() {
  # $1 = pinned hub url (hub.pelican.dev/plugins/<slug>/download/<id>/<file>.zip)
  # Returns "<resolved-url>|<verified-version>" - the pinned url with an empty
  # version when the hub cannot be resolved. The hub has no "latest" alias, so
  # the plugin page is scraped for version -> release-id pairs, and the zip is
  # downloaded and its plugin.json version read before the url is trusted
  # (imports of a stale version are exactly what this avoids). Cached 6h.
  local pinned=$1
  local slug file cache="$PI_ROOT/hub-plugin-versions.cache"
  local now ts id version hit tmp ztmp got rc=1
  slug=$(printf '%s' "$pinned" | sed -n 's|.*/plugins/\([^/]*\)/download/.*|\1|p')
  file=$(printf '%s' "$pinned" | sed -n 's|.*/download/[0-9]*/||p')
  if [ -z "$slug" ] || [ -z "$file" ]; then
    echo "$pinned|"
    return 0
  fi

  now=$(date +%s)
  if [ -f "$cache" ]; then
    hit=$(grep -E "^${slug}\|" "$cache" 2>/dev/null | tail -1 || true)
    if [ -n "$hit" ]; then
      id=$(printf '%s' "$hit" | cut -d'|' -f2)
      version=$(printf '%s' "$hit" | cut -d'|' -f3)
      ts=$(printf '%s' "$hit" | cut -d'|' -f4)
      if [ -n "$id" ] && [ -n "$version" ] && [ -n "$ts" ] && [ $(( now - ts )) -lt 21600 ]; then
        echo "https://hub.pelican.dev/plugins/$slug/download/$id/$file|$version"
        return 0
      fi
    fi
  fi

  tmp=$(mktemp) || { echo "$pinned|"; return 0; }
  if curl -fsSL -m 30 -o "$tmp" "https://hub.pelican.dev/plugins/$slug" 2>/dev/null; then
    # Hub release ids are monotonic: the highest id on the page is the newest
    # release. The zip's own plugin.json decides the recorded version.
    id=$(python3 - "$tmp" <<'PY' 2>/dev/null || true
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
ids = [int(x) for x in re.findall(r"download/(\d+)/[\w.-]+\.zip", h)]
print(max(ids) if ids else "")
PY
)
    id=$(printf '%s' "$id" | tail -1)
    if [ -n "$id" ]; then
      ztmp=$(mktemp /tmp/hub-plugin.XXXXXX.zip) || { rm -f "$tmp"; echo "$pinned|"; return 0; }
      if curl -fsSL -m 120 -o "$ztmp" "https://hub.pelican.dev/plugins/$slug/download/$id/$file" 2>/dev/null; then
        got=$(python3 - "$ztmp" "$slug" <<'PY' 2>/dev/null || true
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
data = json.loads(z.read(sys.argv[2] + "/plugin.json"))
print(data.get("version", ""))
PY
)
        got=$(printf '%s' "$got" | tail -1)
        if [ -n "$got" ]; then
          version="$got"
          mkdir -p "$PI_ROOT" 2>/dev/null || true
          {
            grep -vE "^${slug}\|" "$cache" 2>/dev/null || true
            printf '%s|%s|%s|%s\n' "$slug" "$id" "$version" "$(date +%s)"
          } > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
          chmod 600 "$cache" 2>/dev/null || true
          rc=0
        fi
      fi
      rm -f "$ztmp"
    fi
  fi
  rm -f "$tmp"
  if [ "$rc" = "0" ] && [ -n "$id" ]; then
    echo "https://hub.pelican.dev/plugins/$slug/download/$id/$file|$version"
  else
    echo "$pinned|"
  fi
}

plugins_select_resolve() {
  # Returns "name|url" with the hub url replaced by its newest release when the
  # resolution verified. Falls back to the pinned url otherwise.
  local name=$1 url=$2 resolved r_url r_ver
  case "$url" in
    *hub.pelican.dev/plugins/*)
      resolved=$(plugin_hub_latest_url "$url")
      r_url=${resolved%%|*}
      r_ver=${resolved#*|}
      if [ -n "$r_ver" ] && [ "$r_url" != "$url" ]; then
        echo "$name|$r_url"
        return 0
      fi
      ;;
  esac
  echo "$name|$url"
}

plugins_selected() {
  local sel=""
  case "$PANEL_PLUGINS" in
    all) sel=$(plugin_catalog | awk -F'|' '{print $1"|"$2}') ;;
    none) sel="" ;;
    minimal)
      sel=$(plugin_catalog | grep -E '^(modpack-manager|minecraft-modrinth|mclogs-uploader)\|' || true)
      ;;
    *)
      local line name_u url_u want
      while IFS='|' read -r name_u url_u; do
        [ -n "$name_u" ] || continue
        for want in $(echo "$PANEL_PLUGINS" | tr ',' ' '); do
          if [ "$name_u" = "$want" ]; then
            sel="${sel}${name_u}|${url_u}"$'\n'
          fi
        done
      done <<EOF
$(plugin_catalog)
EOF
      ;;
  esac
  # Resolve hub plugins to their newest release before anything is imported;
  # the pinned ids in the catalog are only a fallback for offline resolution.
  printf '%s' "$sel" | while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    plugins_select_resolve "$name" "$url"
  done
  if [ "$INSTALL_SELF_PLUGINS" = "yes" ]; then
    echo "opsboard|$SELF_PLUGIN_RELEASE_BASE/opsboard.zip"
    echo "perfctl|$SELF_PLUGIN_RELEASE_BASE/perfctl.zip"
  fi
}

plugins_patch_modpack() {
  # modpack-manager (hub plugin) throws a 500 on the Modpacks/Mods pages when no
  # CurseForge API key is set. Patch: CurseForgeService degrades gracefully
  # (isAvailable + empty results), pages clamp curseforge provider to 'all', and
  # the CurseForge pill is hidden - Modrinth/FTB/ATLauncher keep working.
  local dir="$PANEL_DIR/plugins/modpack-manager"
  [ -d "$dir" ] || return 0
  local pscript
  for cand in "${SCRIPT_DIR:-/opt/pelican-installer}/patches/modpack-cf-fallback.py" \
              "${HEAL_DIR:-/opt/pelican-installer}/patches/modpack-cf-fallback.py" \
              "${UPD_DIR:-/opt/pelican-installer}/patches/modpack-cf-fallback.py" \
              "/opt/pelican-installer/patches/modpack-cf-fallback.py"; do
    if [ -f "$cand" ]; then
      pscript="$cand"
      break
    fi
  done
  [ -n "${pscript:-}" ] || { log_err "modpack-cf-fallback.py not found in installer - skipping patch."; return 0; }
  if python3 "$pscript" "$dir"; then
    log "Patched modpack-manager for missing CurseForge key (Modrinth/FTB/ATLauncher fallback)."
  else
    log_err "modpack-manager CurseForge fallback patch reported failures - will retry on the next heal/update run."
  fi
}

plugins_ensure_installed() {
  # Imports/installs plugins that are in the selected set but missing from the
  # panel (e.g. the first install ran before the panel API key was available).
  ensure_app_api_key || return 0
  local name url
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    app_api GET "/plugins/$name"
    if [ "$APP_CODE" = "200" ]; then
      continue
    fi
    log "Plugin '$name' is missing - importing it now..."
    app_api POST "/plugins/import/url" "{\"url\":\"$url\"}"
    if [ "$APP_CODE" = "201" ] || [ "$APP_CODE" = "200" ] || [ "$APP_CODE" = "204" ]; then
      app_api POST "/plugins/$name/install"
      log "Plugin '$name' install queued (HTTP $APP_CODE)."
    else
      log_err "Import failed for $name (HTTP $APP_CODE): $APP_RESP"
    fi
    sleep 2
  done <<EOF
$(plugins_selected)
EOF
}

plugins_reconcile() {
  # Re-enable configured plugins that ended up disabled (idempotent, heal-safe).
  # Pelican has NO p:plugin:enable CLI command - enable state lives in
  # plugins/<id>/plugin.json meta and is toggled via the app API only.
  ensure_app_api_key || return 0
  local name
  while IFS='|' read -r name _url; do
    [ -n "$name" ] || continue
    app_api GET "/plugins/$name"
    [ "$APP_CODE" = "200" ] || continue
    if echo "$APP_RESP" | grep -qE '"status"[^,]*disabled'; then
      app_api POST "/plugins/$name/enable"
      if [ "$APP_CODE" = "200" ] || [ "$APP_CODE" = "204" ]; then
        log "Re-enabled plugin '$name'."
      else
        log_err "Could not re-enable plugin '$name' (HTTP $APP_CODE): $APP_RESP"
      fi
    fi
  done <<EOF
$(plugins_selected)
EOF
}

plugins_update_all() {
  # Panel-side plugin updates via `p:plugin:update` (checks each installed
  # plugin's update_url - hub plugins ship one, ours reads plugins-feed.json
  # published with the plugin zips). "Nothing to update" exits 0 and is fine.
  [ -f "$PANEL_DIR/artisan" ] || return 0
  ensure_app_api_key || return 0
  local php_bin name url
  php_bin="php$(panel_php_version)"
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    app_api GET "/plugins/$name"
    if [ "$APP_CODE" != "200" ]; then
      continue
    fi
    if run_heartbeat_sh "plugin update check ($name)" 1800 \
         'cd "$1" && COMPOSER_ALLOW_SUPERUSER=1 "$2" artisan p:plugin:update "$3"' \
         "$PANEL_DIR" "$php_bin" "$name"; then
      log "Plugin '$name' updated or already current."
    else
      log_err "Plugin '$name' update failed - check the panel logs."
    fi
  done <<EOF
$(plugins_selected)
EOF
  return 0
}

plugins_phase() {
  banner "Phase 11 - Panel plugins ($PANEL_PLUGINS)"
  ensure_service pelican-queue 5 || log_err "Queue worker not running - plugin installs will wait in the queue."

  ensure_app_api_key || {
    log_err "No panel API key available - plugins skipped (rerun the installer later)."
    return 0
  }

  local name url code count=0
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    log "Importing plugin '$name'..."
    app_api POST "/plugins/import/url" "{\"url\":\"$url\"}"
    code=$APP_CODE
    if [ "$code" = "201" ] || [ "$code" = "200" ] || [ "$code" = "204" ]; then
      log "Installing plugin '$name' (queued)..."
      app_api POST "/plugins/$name/install"
      log "Install response: $APP_CODE"
      count=$((count + 1))
    else
      log_err "Import failed for $name (HTTP $code): $APP_RESP"
    fi
    sleep 3
  done <<EOF
$(plugins_selected)
EOF
  log "Plugins processed: $count"

  log "Configuring Modpack Manager..."
  if [ -f "$PANEL_DIR/.env" ] && ! grep -q '^MODPACK_MANAGER_STORE_METADATA' "$PANEL_DIR/.env"; then
    printf '\nMODPACK_MANAGER_STORE_METADATA=true\n' >> "$PANEL_DIR/.env"
  fi
  plugins_sync_curseforge_key
  plugins_verify_curseforge_key

  log "Tagging Java eggs as 'minecraft' (required for the Modpacks page)..."
  mysql <<SQL 2>>"$INSTALL_LOG" || true
UPDATE pelican.eggs
SET tags = JSON_ARRAY_APPEND(tags, '$', 'minecraft')
WHERE docker_images LIKE '%yolks:java_%' AND NOT JSON_CONTAINS(tags, '"minecraft"');
SQL

  log "Rebuilding panel caches..."
  restart_service pelican-queue
  plugins_patch_modpack
  # shellcheck source=../lib/tune.sh
  . "$SCRIPT_DIR/lib/tune.sh"
  panel_optimize || true
  log "Plugins installed and configured."
}

modpack_env_get() {
  # Current value of a key in the panel .env (quotes stripped).
  local key=$1
  sed -n "s/^${key}=//p" "$PANEL_DIR/.env" 2>/dev/null | tail -1 | sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

modpack_env_set() {
  # Replace (or append) KEY='value' in the panel .env without expanding the
  # value - CurseForge keys start with $2a$10$. Single quotes are escaped.
  local key=$1 value=$2 tmp
  [ -f "$PANEL_DIR/.env" ] || return 1
  value=${value//\'/\\\'}
  tmp=$(mktemp) || return 1
  if ! MODPACK_KEY="$key" MODPACK_VAL="$value" awk '
        BEGIN { key = ENVIRON["MODPACK_KEY"]; val = ENVIRON["MODPACK_VAL"]; q = sprintf("%c", 39) }
        index($0, key "=") == 1 { print key "=" q val q; found = 1; next }
        { print }
        END { if (!found) print key "=" q val q }
      ' "$PANEL_DIR/.env" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod --reference="$PANEL_DIR/.env" "$tmp" 2>/dev/null || true
  chown --reference="$PANEL_DIR/.env" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$PANEL_DIR/.env"
}

plugins_sync_curseforge_key() {
  # Keep MODPACK_MANAGER_CURSEFORGE_API_KEY in sync with the installer config.
  # The old append-only logic skipped the write whenever *any* line with that
  # key existed - including a stale or empty value (e.g. one saved from the
  # plugin settings UI before the key was configured), which the panel then
  # reports as an invalid/missing key forever.
  [ -n "${CURSEFORGE_API_KEY:-}" ] || return 0
  [ -f "$PANEL_DIR/.env" ] || return 0
  local current
  current=$(modpack_env_get MODPACK_MANAGER_CURSEFORGE_API_KEY)
  if [ "$current" = "$CURSEFORGE_API_KEY" ]; then
    return 0
  fi
  if ! modpack_env_set MODPACK_MANAGER_CURSEFORGE_API_KEY "$CURSEFORGE_API_KEY"; then
    log_err "Could not update the CurseForge API key in the panel .env."
    return 1
  fi
  if [ -n "$current" ]; then
    log "Updated the CurseForge API key in the panel .env (the stored value differed)."
  else
    log "CurseForge API key added to panel .env."
  fi
  # The value must be visible immediately, not only after the next cache build;
  # the queue worker loads config at boot, so it has to recycle too or queued
  # modpack installs keep seeing the old (missing) key.
  (cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 php artisan config:clear) >>"$INSTALL_LOG" 2>&1 || true
  (cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 php artisan queue:restart) >>"$INSTALL_LOG" 2>&1 || true
  return 0
}

plugins_verify_curseforge_key() {
  # Definitive check against the CurseForge API (no more guessing whether the
  # panel "sees" the key). The key never appears in the process list.
  [ -n "${CURSEFORGE_API_KEY:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local hdr code base
  base="${CURSEFORGE_API_BASE:-https://api.curseforge.com}"
  hdr=$(mktemp) || return 0
  chmod 600 "$hdr" 2>/dev/null || true
  printf 'header = "x-api-key: %s"\n' "$CURSEFORGE_API_KEY" > "$hdr"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -K "$hdr" \
    "$base/v1/games?index=0&pageSize=1" 2>/dev/null || true)
  rm -f "$hdr"
  case "$code" in
    200)
      log "CurseForge API key verified (api.curseforge.com accepted it)."
      ;;
    401|403)
      log_err "CurseForge rejected the API key (HTTP $code) - create a new key at https://console.curseforge.com and update CURSEFORGE_API_KEY in $CONF_FILE."
      ;;
    *)
      log_err "Could not verify the CurseForge API key (HTTP ${code:-none}) - continuing."
      ;;
  esac
  return 0
}
