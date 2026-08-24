FABRIC_INSTALLER_JAR=/var/lib/pelican/fabric-installer.jar
JAR_REPORT_FILE="/var/www/pelican/storage/app/pelican-jars.json"

fabric_installer_ensure() {
  if [ ! -f "$FABRIC_INSTALLER_JAR" ] || [ "$(stat -c %s "$FABRIC_INSTALLER_JAR" 2>/dev/null || echo 0)" -lt 500000 ]; then
    mkdir -p /var/lib/pelican
    curl -fsSL -m 120 -o "$FABRIC_INSTALLER_JAR.tmp" \
      "https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.2/fabric-installer-1.1.2.jar" 2>/dev/null || return 1
    mv "$FABRIC_INSTALLER_JAR.tmp" "$FABRIC_INSTALLER_JAR"
  fi
}

game_jar_download() {
  local srvdir=$1 mc=$2
  command -v curl >/dev/null 2>&1 || return 1
  local jar_url
  jar_url=$(curl -fsSL -m 30 "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json" 2>/dev/null \
    | python3 -c "
import sys, json, urllib.request
mc = '$mc'
try:
    d = json.load(sys.stdin)
    for v in d['versions']:
        if v['id'] == mc:
            vd = json.load(urllib.request.urlopen(v['url']))
            print(vd['downloads']['server']['url'])
            break
except Exception:
    pass
") || jar_url=""
  [ -n "$jar_url" ] || return 1
  if curl -fsSL -m 300 -o "$srvdir/minecraft-server.jar.tmp" "$jar_url" 2>/dev/null && [ "$(stat -c %s "$srvdir/minecraft-server.jar.tmp" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    rm -f "$srvdir/minecraft-server.jar" "$srvdir/server.jar"
    mv "$srvdir/minecraft-server.jar.tmp" "$srvdir/minecraft-server.jar"
    ln -sfn minecraft-server.jar "$srvdir/server.jar"
    chown -h pelican:pelican "$srvdir/server.jar" 2>/dev/null || true
    return 0
  fi
  rm -f "$srvdir/minecraft-server.jar.tmp" 2>/dev/null
  return 1
}

server_var() {
  mysql -N -B -e "SELECT sv.variable_value FROM pelican.egg_variables ev JOIN pelican.server_variables sv ON sv.variable_id=ev.id JOIN pelican.servers s ON s.id=sv.server_id WHERE s.uuid='$1' AND ev.env_variable='$2';" 2>/dev/null | head -1
}

server_jars_report_add() {
  printf '{"uuid":"%s","jar_ok":%s,"jarfile":"%s","size":%s,"fixed":%s}\n' "$1" "$2" "$3" "$4" "$5" >> "$JAR_REPORT_LINES"
}

set_server_var() {
  mysql -e "UPDATE pelican.server_variables sv JOIN pelican.egg_variables ev ON ev.id=sv.variable_id SET sv.variable_value='$2' WHERE ev.env_variable='SERVER_JARFILE' AND sv.server_id=(SELECT id FROM pelican.servers WHERE uuid='$1');" 2>/dev/null || true
}

fabric_install_inplace() {
  local srvdir=$1 mc=$2 ldr=$3 launch_jar=""
  log "Server $1: installing Fabric $mc/$ldr directly into the volume..."
  fabric_installer_ensure || { log_err "Server $1: could not fetch fabric installer."; return 1; }
  if ! docker run --rm \
      -v "$srvdir:/data:rw" \
      -v "$FABRIC_INSTALLER_JAR:/fabric-installer.jar:ro" \
      -w /data ghcr.io/pelican-eggs/yolks:java_25 \
      java -jar /fabric-installer.jar server -mcversion "$mc" -loader "$ldr" -dir /data >/dev/null 2>&1; then
    log_err "Server $1: fabric installer failed for $mc/$ldr - check https://fabricmc.net/versions"
    return 1
  fi

  if [ -f "$srvdir/fabric-server-launch.jar" ]; then
    launch_jar=fabric-server-launch.jar
  elif [ -f "$srvdir/server.jar" ]; then
    launch_jar=server.jar
  fi
  [ -n "$launch_jar" ] || { log_err "Server $1: installer ran but produced no launch jar."; return 1; }

  if game_jar_download "$srvdir" "$mc"; then
    log "Server $1: downloaded official game jar (bundles all game libraries)."
  else
    log_err "Server $1: could not download official game jar."
    local version_jar
    version_jar=$(find "$srvdir/versions" -name 'server-*.jar' -size +100k 2>/dev/null | head -1)
    if [ -n "$version_jar" ]; then
      cp -f "$version_jar" "$srvdir/minecraft-server.jar"
      [ -e "$srvdir/server.jar" ] || ln -sfn minecraft-server.jar "$srvdir/server.jar"
      chown -h pelican:pelican "$srvdir/server.jar" 2>/dev/null || true
    else
      log_err "Server $1: game libraries may be missing."
    fi
  fi

  chown -R pelican:pelican "$srvdir/$launch_jar" "$srvdir/libraries" "$srvdir/versions" "$srvdir/minecraft-server.jar" 2>/dev/null || true
  set_server_var "${srvdir##*/}" "$launch_jar"
  log "Server ${srvdir##*/}: installed $launch_jar (game jar + libraries)."
  echo "$launch_jar"
}

server_jars_fix() {
  command -v mysql >/dev/null 2>&1 || return 0
  command -v docker >/dev/null 2>&1 || return 0
  JAR_REPORT_LINES=$(mktemp)
  local uuid srvdir jarfile expected ok fixed size mc ldr rep_count=0

  while IFS=$'\t' read -r uuid; do
    [ -n "$uuid" ] || continue
    srvdir="/var/lib/pelican/volumes/$uuid"
    [ -d "$srvdir" ] || continue

    jarfile=$(server_var "$uuid" SERVER_JARFILE)
    jarfile=${jarfile:-server.jar}
    expected="$srvdir/$jarfile"
    ok=false
    fixed=false
    size=0

    if [ -f "$srvdir/fabric-server-launch.jar" ]; then
      local launch_size game_jar expected_jar
      launch_size=$(stat -c %s "$srvdir/fabric-server-launch.jar" 2>/dev/null || echo 0)
      game_jar=""
      if [ -f "$srvdir/minecraft-server.jar" ] && [ "$(stat -c %s "$srvdir/minecraft-server.jar" 2>/dev/null || echo 0)" -gt 100000 ]; then
        game_jar=minecraft-server.jar
      elif [ -f "$srvdir/server.jar" ] && [ "$(stat -c %s "$srvdir/server.jar" 2>/dev/null || echo 0)" -gt 100000 ]; then
        game_jar=server.jar
      fi
      if [ ! -L "$srvdir/fabric-server-launch.jar" ] && [ "$launch_size" -lt 200000 ] && [ -n "$game_jar" ]; then
        if [ "$jarfile" != "fabric-server-launch.jar" ]; then
          set_server_var "$uuid" "fabric-server-launch.jar"
          fixed=true
        fi
        expected_jar=$(grep '^serverJar=' "$srvdir/fabric-server-launcher.properties" 2>/dev/null | cut -d= -f2-)
        expected_jar=${expected_jar:-server.jar}
        if [ "$game_jar" != "$expected_jar" ] && [ ! -e "$srvdir/$expected_jar" ]; then
          ln -sf "$game_jar" "$srvdir/$expected_jar"
          chown -h pelican:pelican "$srvdir/$expected_jar" 2>/dev/null || true
          log "Server $uuid: linked $expected_jar -> $game_jar (fabric launcher requirement)."
          fixed=true
        fi
        ok=true
        size=$(stat -c %s "$srvdir/$game_jar" 2>/dev/null || echo 0)
        server_jars_report_add "$uuid" "$ok" "$jarfile" "$size" "$fixed"
        continue
      fi
    else
      if [ -f "$expected" ] && [ "$(stat -c %s "$expected" 2>/dev/null || echo 0)" -gt 100000 ]; then
        ok=true
        size=$(stat -c %s "$expected" 2>/dev/null || echo 0)
        server_jars_report_add "$uuid" "$ok" "$jarfile" "$size" "$fixed"
        continue
      fi

      local candidate
      candidate=$(find "$srvdir" -maxdepth 1 -name '*.jar' -size +100k ! -name '*installer*' ! -name '*launch*' ! -name 'minecraft-server.jar' 2>/dev/null | head -1)
      if [ -n "$candidate" ]; then
        log "Server $uuid: linking $jarfile -> $(basename "$candidate")"
        ln -sf "$(basename "$candidate")" "$expected"
        ok=true
        fixed=true
        size=$(stat -c %s "$expected" 2>/dev/null || echo 0)
        server_jars_report_add "$uuid" "$ok" "$jarfile" "$size" "$fixed"
        continue
      fi
    fi

    mc=$(server_var "$uuid" MC_VERSION)
    if [ -n "$mc" ]; then
      ldr=$(server_var "$uuid" LOADER_VERSION)
      ldr=${ldr:-latest}
      local installed
      installed=$(fabric_install_inplace "$srvdir" "$mc" "$ldr")
      if [ -n "$installed" ]; then
        jarfile=$installed
        expected="$srvdir/$jarfile"
        ok=true
        fixed=true
        size=$(stat -c %s "$expected" 2>/dev/null || echo 0)
      fi
    fi

    server_jars_report_add "$uuid" "$ok" "$jarfile" "$size" "$fixed"
  done < <(mysql -N -B -e "SELECT s.uuid FROM pelican.servers s WHERE s.uuid IS NOT NULL;" 2>/dev/null)

  if [ -s "$JAR_REPORT_LINES" ]; then
    jq -s 'map({key: .uuid, value: del(.uuid)}) | from_entries' "$JAR_REPORT_LINES" \
      > "$JAR_REPORT_FILE" 2>/dev/null || true
    chown www-data:www-data "$JAR_REPORT_FILE" 2>/dev/null || true
  elif [ -f "$JAR_REPORT_FILE" ]; then
    echo '{}' > "$JAR_REPORT_FILE"
    chown www-data:www-data "$JAR_REPORT_FILE" 2>/dev/null || true
  fi
  rm -f "$JAR_REPORT_LINES"
}

process_repair_requests() {
  mkdir -p /var/www/pelican/storage/app/requests
  local req uuid
  for req in /var/www/pelican/storage/app/requests/repair-*.req; do
    [ -f "$req" ] || continue
    uuid=$(basename "$req" .req | sed 's/^repair-//')
    log "Repair requested for server $uuid - running jar fixer."
    server_jars_fix
    rm -f "$req"
  done
}

volume_changed_since_last_scan() {
  local srvdir=$1 last=$2 m
  m=$(stat -c %Y "$srvdir" 2>/dev/null || echo 0)
  [ "$m" -gt "$last" ]
}

fix_volume_permissions() {
  local srvdir=$1 fixed=false
  if [ "$(find "$srvdir" -type f ! -perm -004 2>/dev/null | wc -l)" -gt 0 ]; then
    find "$srvdir" -type f ! -perm -004 -exec chmod 644 {} \; 2>/dev/null
    fixed=true
  fi
  if [ "$(find "$srvdir" -type d ! -perm -005 2>/dev/null | wc -l)" -gt 0 ]; then
    find "$srvdir" -type d ! -perm -005 -exec chmod 755 {} \; 2>/dev/null
    fixed=true
  fi
  if [ "$fixed" = "true" ]; then
    chown -R pelican:pelican "$srvdir" 2>/dev/null || true
    log "Server $1: fixed unreadable files (modpack extraction permissions)."
  fi
}

server_permissions_fix() {
  command -v mysql >/dev/null 2>&1 || return 0
  local marker="$PI_ROOT/.perm-scan-last"
  mkdir -p "$PI_ROOT"
  local last=0
  [ -f "$marker" ] && last=$(cat "$marker" 2>/dev/null || echo 0)
  local uuid srvdir scanned_any=false
  while IFS= read -r uuid; do
    [ -n "$uuid" ] || continue
    srvdir="/var/lib/pelican/volumes/$uuid"
    [ -d "$srvdir" ] || continue
    if volume_changed_since_last_scan "$srvdir" "$last"; then
      fix_volume_permissions "$srvdir" "$uuid"
      scanned_any=true
    fi
  done < <(mysql -N -B -e "SELECT s.uuid FROM pelican.servers s WHERE s.uuid IS NOT NULL;" 2>/dev/null)
  date +%s > "$marker"
  return 0
}
