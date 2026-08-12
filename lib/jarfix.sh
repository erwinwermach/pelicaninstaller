server_jars_fix() {
  command -v mysql >/dev/null 2>&1 || return 0
  local uuid egg_id jarfile expected candidate mc ldr srvdir
  while IFS=$'\t' read -r uuid egg_id; do
    [ -n "$uuid" ] || continue
    srvdir="/var/lib/pelican/volumes/$uuid"
    [ -d "$srvdir" ] || continue

    jarfile=$(mysql -N -B -e "SELECT sv.variable_value FROM pelican.egg_variables ev JOIN pelican.server_variables sv ON sv.variable_id=ev.id JOIN pelican.servers s ON s.id=sv.server_id WHERE s.uuid='$uuid' AND ev.env_variable='SERVER_JARFILE';" 2>/dev/null | head -1)
    jarfile=${jarfile:-server.jar}
    expected="$srvdir/$jarfile"

    if [ -f "$expected" ] && [ "$(stat -c %s "$expected" 2>/dev/null || echo 0)" -gt 100000 ]; then
      continue
    fi

    candidate=$(find "$srvdir" -maxdepth 1 -name '*.jar' -size +100k ! -name '*installer*' ! -name '*launcher*' 2>/dev/null | head -1)
    if [ -n "$candidate" ]; then
      log "Server $uuid: linking $jarfile -> $(basename "$candidate")"
      ln -sf "$(basename "$candidate")" "$expected"
      continue
    fi

    mc=$(mysql -N -B -e "SELECT sv.variable_value FROM pelican.egg_variables ev JOIN pelican.server_variables sv ON sv.variable_id=ev.id JOIN pelican.servers s ON s.id=sv.server_id WHERE s.uuid='$uuid' AND ev.env_variable='MC_VERSION';" 2>/dev/null | head -1)
    [ -n "$mc" ] || continue
    ldr=$(mysql -N -B -e "SELECT sv.variable_value FROM pelican.egg_variables ev JOIN pelican.server_variables sv ON sv.variable_id=ev.id JOIN pelican.servers s ON s.id=sv.server_id WHERE s.uuid='$uuid' AND ev.env_variable='LOADER_VERSION';" 2>/dev/null | head -1)
    ldr=${ldr:-latest}

    log "Server $uuid: no server jar found - downloading Fabric server for $mc/$ldr"
    if curl -fsSL -m 180 -o "$expected.tmp" "https://meta.fabricmc.net/v2/versions/loader/$mc/$ldr/server/jar" 2>/dev/null \
      && [ "$(stat -c %s "$expected.tmp" 2>/dev/null || echo 0)" -gt 100000 ]; then
      mv "$expected.tmp" "$expected"
      chown -R pelican:pelican "$expected" 2>/dev/null || true
      log "Server $uuid: server.jar installed ($jarfile)."
    else
      rm -f "$expected.tmp"
      log_err "Server $uuid: fabric server download failed for $mc/$ldr - check https://fabricmc.net/versions"
    fi
  done < <(mysql -N -B -e "SELECT s.uuid, s.egg_id FROM pelican.servers s WHERE s.uuid IS NOT NULL;" 2>/dev/null)
}
