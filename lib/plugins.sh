PANEL_PLUGINS=${PANEL_PLUGINS:-minimal}
INSTALL_SELF_PLUGINS=${INSTALL_SELF_PLUGINS:-yes}

SELF_PLUGIN_RELEASE_BASE="${SELF_PLUGIN_RELEASE_BASE:-https://github.com/erwinwermach/pelicaninstaller/releases/latest/download}"

plugin_catalog() {
  cat <<'EOF'
modpack-manager|https://hub.pelican.dev/plugins/modpack-manager/download/187/modpack-manager.zip
minecraft-modrinth|https://hub.pelican.dev/plugins/minecraft-modrinth/download/167/minecraft-modrinth.zip
player-counter|https://hub.pelican.dev/plugins/player-counter/download/168/player-counter.zip
system-status-monitor|https://hub.pelican.dev/plugins/system-status-monitor/download/102/system-status-monitor.zip
mclogs-uploader|https://hub.pelican.dev/plugins/mclogs-uploader/download/149/mclogs-uploader.zip
EOF
}

plugins_selected() {
  case "$PANEL_PLUGINS" in
    all) plugin_catalog | awk -F'|' '{print $1"|"$2}' ;;
    none) echo "" ;;
    minimal)
      plugin_catalog | grep -E '^(modpack-manager|minecraft-modrinth|mclogs-uploader)\|' || true
      ;;
    *)
      local line name_u url_u
      while IFS='|' read -r name_u url_u; do
        local want
        for want in $(echo "$PANEL_PLUGINS" | tr ',' ' '); do
          [ "$name_u" = "$want" ] && echo "$name_u|$url_u"
        done
      done <<EOF
$(plugin_catalog)
EOF
      ;;
  esac
  if [ "$INSTALL_SELF_PLUGINS" = "yes" ]; then
    echo "opsboard|$SELF_PLUGIN_RELEASE_BASE/opsboard.zip"
    echo "perfctl|$SELF_PLUGIN_RELEASE_BASE/perfctl.zip"
  fi
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

  log "Tagging Java eggs as 'minecraft' (required for the Modpacks page)..."
  mysql <<SQL 2>>"$INSTALL_LOG" || true
UPDATE pelican.eggs
SET tags = JSON_ARRAY_APPEND(tags, '$', 'minecraft')
WHERE docker_images LIKE '%pterodactyl/yolks:java_%' AND NOT JSON_CONTAINS(tags, '"minecraft"');
SQL

  log "Rebuilding panel caches..."
  restart_service pelican-queue
  # shellcheck source=../lib/tune.sh
  . "$SCRIPT_DIR/lib/tune.sh"
  panel_optimize || true
  log "Plugins installed and configured."
}
