PLUGIN_LIST="modpack-manager|https://hub.pelican.dev/plugins/modpack-manager/download/187/modpack-manager.zip
minecraft-modrinth|https://hub.pelican.dev/plugins/minecraft-modrinth/download/167/minecraft-modrinth.zip
player-counter|https://hub.pelican.dev/plugins/player-counter/download/168/player-counter.zip
system-status-monitor|https://hub.pelican.dev/plugins/system-status-monitor/download/102/system-status-monitor.zip
mclogs-uploader|https://hub.pelican.dev/plugins/mclogs-uploader/download/149/mclogs-uploader.zip"

plugins_phase() {
  banner "Phase 9/9 - Installing panel plugins"
  ensure_service pelican-queue 5 || log_err "Queue worker not running - plugin installs will wait in the queue."

  ensure_app_api_key || {
    log_err "No panel API key available - plugins skipped (rerun the installer later)."
    return 0
  }

  local plugin name url code
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    log "Importing plugin '$name'..."
    app_api POST "/plugins/import/url" "{\"url\":\"$url\"}"
    code=$APP_CODE
    log "Import response: $code"
    if [ "$code" = "201" ] || [ "$code" = "200" ] || [ "$code" = "204" ]; then
      log "Installing plugin '$name' (queued)..."
      app_api POST "/plugins/$name/install"
      log "Install response: $APP_CODE"
    else
      log_err "Import failed for $name: $APP_RESP"
    fi
    sleep 3
  done <<EOF
$PLUGIN_LIST
EOF

  log "Configuring Modpack Manager..."
  if [ -f "$PANEL_DIR/.env" ] && ! grep -q '^MODPACK_MANAGER_STORE_METADATA' "$PANEL_DIR/.env"; then
    printf '\nMODPACK_MANAGER_STORE_METADATA=true\n' >> "$PANEL_DIR/.env"
  fi

  log "Tagging Java eggs as 'minecraft' (required for the Modpacks page)..."
  mysql <<SQL 2>>"$INSTALL_LOG" || true
UPDATE pelican.eggs
SET tags = JSON_ARRAY_APPEND(IF(JSON_CONTAINS(tags, '"minecraft"'), tags, tags), '$', 'minecraft')
WHERE docker_images LIKE '%pterodactyl/yolks:java_%' AND NOT JSON_CONTAINS(tags, '"minecraft"');
SQL

  log "Restarting queue worker and clearing caches..."
  restart_service pelican-queue
  (cd "$PANEL_DIR" && php artisan optimize:clear) >>"$INSTALL_LOG" 2>&1 || true
  log "Plugins installed and configured."
}
