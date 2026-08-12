FABRIC_INSTALLER_JAR=/var/lib/pelican/fabric-installer.jar

fabric_installer_ensure() {
  if [ ! -f "$FABRIC_INSTALLER_JAR" ] || [ "$(stat -c %s "$FABRIC_INSTALLER_JAR" 2>/dev/null || echo 0)" -lt 100000 ]; then
    mkdir -p /var/lib/pelican
    curl -fsSL -m 120 -o "$FABRIC_INSTALLER_JAR.tmp" \
      "https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.2/fabric-installer-1.1.2.jar" 2>/dev/null || return 1
    mv "$FABRIC_INSTALLER_JAR.tmp" "$FABRIC_INSTALLER_JAR"
  fi
}

server_var() {
  mysql -N -B -e "SELECT sv.variable_value FROM pelican.egg_variables ev JOIN pelican.server_variables sv ON sv.variable_id=ev.id JOIN pelican.servers s ON s.id=sv.server_id WHERE s.uuid='$1' AND ev.env_variable='$2';" 2>/dev/null | head -1
}

server_jars_fix() {
  command -v mysql >/dev/null 2>&1 || return 0
  command -v docker >/dev/null 2>&1 || return 0
  local uuid srvdir jarfile expected candidate mc ldr stage

  while IFS=$'\t' read -r uuid; do
    [ -n "$uuid" ] || continue
    srvdir="/var/lib/pelican/volumes/$uuid"
    [ -d "$srvdir" ] || continue

    jarfile=$(server_var "$uuid" SERVER_JARFILE)
    jarfile=${jarfile:-server.jar}
    expected="$srvdir/$jarfile"

    # Fabric layout: fabric-server-launch.jar is a small stub by design; the
    # real game jar lives at minecraft-server.jar next to it.
    if [ -f "$srvdir/fabric-server-launch.jar" ]; then
      if [ -f "$srvdir/minecraft-server.jar" ] && [ "$(stat -c %s "$srvdir/minecraft-server.jar" 2>/dev/null || echo 0)" -gt 100000 ]; then
        if [ "$jarfile" != "fabric-server-launch.jar" ]; then
          mysql -e "UPDATE pelican.server_variables sv JOIN pelican.egg_variables ev ON ev.id=sv.variable_id SET sv.variable_value='fabric-server-launch.jar' WHERE ev.env_variable='SERVER_JARFILE' AND sv.server_id=(SELECT id FROM pelican.servers WHERE uuid='$uuid');" 2>/dev/null || true
        fi
        continue
      fi
    fi

    if [ -f "$expected" ] && [ "$(stat -c %s "$expected" 2>/dev/null || echo 0)" -gt 100000 ]; then
      continue
    fi

    candidate=$(find "$srvdir" -maxdepth 1 -name '*.jar' -size +100k ! -name '*installer*' ! -name '*launch*' ! -name 'minecraft-server.jar' 2>/dev/null | head -1)
    if [ -n "$candidate" ]; then
      log "Server $uuid: linking $jarfile -> $(basename "$candidate")"
      ln -sf "$(basename "$candidate")" "$expected"
      continue
    fi

    mc=$(server_var "$uuid" MC_VERSION)
    [ -n "$mc" ] || continue
    ldr=$(server_var "$uuid" LOADER_VERSION)
    ldr=${ldr:-latest}

    log "Server $uuid: no server jar - running Fabric installer for $mc/$ldr"
    fabric_installer_ensure || { log_err "Server $uuid: could not fetch fabric installer."; continue; }

    stage=$(mktemp -d)
    cp -r "$srvdir/." "$stage/" 2>/dev/null
    chmod -R ugo+rwX "$stage" 2>/dev/null || true

    if docker run --rm -u 0 \
        -v "$stage:/data:rw" \
        -v "$FABRIC_INSTALLER_JAR:/fabric-installer.jar:ro" \
        -w /data ghcr.io/pelican-eggs/yolks:java_25 \
        java -jar /fabric-installer.jar server -mcversion "$mc" -loader "$ldr" -dir /data >/dev/null 2>&1; then

      launch_jar=""
      [ -f "$stage/fabric-server-launch.jar" ] && launch_jar=fabric-server-launch.jar
      [ -z "$launch_jar" ] && [ -f "$stage/server.jar" ] && launch_jar=server.jar

      if [ -n "$launch_jar" ]; then
        cp -f "$stage/$launch_jar" "$srvdir/$launch_jar"
        game_jar=$(find "$stage/versions" -name 'server-*.jar' -size +100k 2>/dev/null | head -1)
        if [ -n "$game_jar" ]; then
          cp -f "$game_jar" "$srvdir/minecraft-server.jar"
        fi
        cp -rn "$stage/libraries/." "$srvdir/libraries/" 2>/dev/null || true
        cp -rn "$stage/versions/." "$srvdir/versions/" 2>/dev/null || true
        chown -R pelican:pelican "$srvdir/$launch_jar" "$srvdir/minecraft-server.jar" "$srvdir/libraries" "$srvdir/versions" 2>/dev/null || true

        mysql -e "UPDATE pelican.server_variables sv JOIN pelican.egg_variables ev ON ev.id=sv.variable_id SET sv.variable_value='$launch_jar' WHERE ev.env_variable='SERVER_JARFILE' AND sv.server_id=(SELECT id FROM pelican.servers WHERE uuid='$uuid');" 2>/dev/null || true
        log "Server $uuid: installed $launch_jar (game jar + libraries)."
      else
        log_err "Server $uuid: installer ran but produced no launch jar."
      fi
    else
      log_err "Server $uuid: fabric installer failed for $mc/$ldr - check https://fabricmc.net/versions"
    fi

    rm -rf "$stage"
  done < <(mysql -N -B -e "SELECT s.uuid FROM pelican.servers s WHERE s.uuid IS NOT NULL;" 2>/dev/null)
}
