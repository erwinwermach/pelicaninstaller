PERF_REC_FILE="$PANEL_STORAGE/perf-recommendations.json"
PERF_APPLIED_FILE="$PI_ROOT/perf-applied.json"
PERF_REQUEST_DIR="$PANEL_STORAGE/requests"

perf_profiles_list() {
  cat <<'EOF'
mc-paper|PaperMC/Purpin-style servers: G1 tuning sized to the allocation
mc-fabric|Fabric modded: G1 tuning with larger region size for big heaps
mc-forge|Forge/NeoForge modded: G1 tuning with larger region size
mc-generic|Vanilla/other Java Minecraft: balanced Aikar-style set
proxy-java|Velocity/Waterfall/BungeeCord proxies: small steady heap
source-engine|Source engine (CS/GMod/TF2): srcds startup args
python|Python bots/apps: unbuffered output, no bytecode writes
nodejs|Node.js apps: heap cap matched to the allocation
EOF
}

perf_detect_profile() {
  local egg_name=$1 images=$2 startup=$3
  local hay
  hay=$(printf '%s\n%s\n%s' "$egg_name" "$images" "$startup" | tr '[:upper:]' '[:lower:]')

  case "$hay" in
    *paper*|*purpur*|*pufferfish*|*leaves*) echo mc-paper; return ;;
    *velocity*|*waterfall*|*bungee*) echo proxy-java; return ;;
    *fabric*) echo mc-fabric; return ;;
    *forge*|*neoforge*) echo mc-forge; return ;;
  esac

  case "$hay" in
    *srcds*|*counter-strike*|*counterstrike*|*csgo*|*cs2*|*garrysmod*|*gmod*|*team-fortress*|*tf2*|*left-4-dead*|*l4d*)
      echo source-engine; return ;;
  esac

  case "$hay" in
    *yolks:python*|*python*egg*) echo python; return ;;
    *yolks:nodejs*|*nodejs*egg*) echo nodejs; return ;;
    *yolks:java*) echo mc-generic; return ;;
  esac

  case "$hay" in
    *minecraft*|*.jar*) echo mc-generic; return ;;
    *python3*|*" python "*) echo python; return ;;
    *"node "*|*npm*) echo nodejs; return ;;
    *) echo generic; return ;;
  esac
}

perf_heap_mb() {
  local mem=$1 pct=${2:-72}
  local h=$(( mem * pct / 100 ))
  [ "$h" -lt 512 ] && h=512
  [ "$h" -gt 12288 ] && h=12288
  echo $h
}

perf_java_flags() {
  local heap=$1
  local region="8M"
  [ "$heap" -ge 12288 ] && region="16M"
  printf -- '-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=%s -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true' "$region"
}

perf_recommend_startup() {
  local profile=$1 mem=$2 startup=$3
  local cleaned heap flags
  case "$profile" in
    mc-paper|mc-fabric|mc-forge|mc-generic)
      heap=$(perf_heap_mb "$mem" 72)
      flags=$(perf_java_flags "$heap")
      if [ "$profile" = "mc-paper" ]; then
        flags="$flags -DPaper.IgnoreJavaVersion=true"
      fi
      cleaned=$(printf '%s' "$startup" | tr ' ' '\n' | grep -vE '^-(Xms|Xmx|XX:)' | paste -sd' ')
      if printf '%s' "$cleaned" | grep -qiE '(^|[[:space:]])java([[:space:]]|$)'; then
        printf '%s' "$cleaned" | sed -E "s|(java[[:space:]])|\\1-Xms${heap}M -Xmx${heap}M $flags |"
      else
        printf 'java -Xms%sM -Xmx%sM %s %s' "$heap" "$heap" "$flags" "$cleaned"
      fi
      ;;
    proxy-java)
      heap=$(perf_heap_mb "$mem" 50)
      [ "$heap" -gt 2048 ] && heap=2048
      cleaned=$(printf '%s' "$startup" | tr ' ' '\n' | grep -vE '^-(Xms|Xmx|XX:)' | paste -sd' ')
      if printf '%s' "$cleaned" | grep -qiE '(^|[[:space:]])java([[:space:]]|$)'; then
        printf '%s' "$cleaned" | sed -E "s|(java[[:space:]])|\\1-Xms${heap}M -Xmx${heap}M -XX:+UseG1GC -XX:G1HeapRegionSize=4M -XX:+ParallelRefProcEnabled |"
      else
        printf 'java -Xms%sM -Xmx%sM %s' "$heap" "$heap" "$cleaned"
      fi
      ;;
    source-engine)
      printf '%s -nobreakpad -novid' "${startup% }"
      ;;
    python)
      printf 'PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 %s' "$startup"
      ;;
    nodejs)
      heap=$(perf_heap_mb "$mem" 75)
      printf '%s --max-old-space-size=%s' "${startup% }" "$heap"
      ;;
    *)
      printf '%s' "$startup"
      ;;
  esac
}

perf_reason_text() {
  local profile=$1 ooms=$2
  local base
  case "$profile" in
    mc-paper) base="PaperMC detected - G1 garbage collector tuned for low pause times." ;;
    mc-fabric) base="Fabric server detected - G1 tuned for modded workloads." ;;
    mc-forge) base="Forge/NeoForge server detected - G1 tuned for modded workloads." ;;
    mc-generic) base="Java Minecraft server detected - balanced Aikar-style flag set." ;;
    proxy-java) base="Proxy software detected - right-sized steady heap instead of oversized defaults." ;;
    source-engine) base="Source engine server detected - standard stable srcds arguments." ;;
    python) base="Python workload detected - unbuffered console output, no bytecode pollution." ;;
    nodejs) base="Node.js app detected - heap capped to the allocation to avoid host OOM." ;;
    *) echo "No specific tuning known for this egg."; return ;;
  esac
  if [ "${ooms:-0}" -gt 0 ]; then
    base="$base Recent OOM/crash activity was recorded, so the heap is conservatively sized."
  fi
  echo "$base"
}

perf_recent_ooms() {
  local uuid=$1
  [ -f "$PANEL_STORAGE/crashlog/index-server-$uuid.json" ] || { echo 0; return; }
  jq --arg u "$uuid" '[.events[]? | select((.oom // false))] | length' \
    "$PANEL_STORAGE/crashlog/index-server-$uuid.json" 2>/dev/null || echo 0
}

perf_sql_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

perf_mirror_applied() {
  [ -f "$PERF_APPLIED_FILE" ] || echo '{}' > "$PERF_APPLIED_FILE"
  cp -f "$PERF_APPLIED_FILE" "$PANEL_STORAGE/perf-applied-public.json" 2>/dev/null || true
  chown www-data:www-data "$PANEL_STORAGE/perf-applied-public.json" 2>/dev/null || true
  chmod 644 "$PANEL_STORAGE/perf-applied-public.json" 2>/dev/null || true
}

perf_scan() {
  command -v mysql >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$PANEL_STORAGE" ] || return 0

  local lines
  lines=$(mktemp)
  local query="SELECT s.uuid, COALESCE(s.name,''), COALESCE(s.startup,''), COALESCE(s.memory,1024), COALESCE(e.name,''), COALESCE(e.docker_images,'') FROM pelican.servers s LEFT JOIN pelican.eggs e ON s.egg_id = e.id WHERE s.uuid IS NOT NULL;"
  while IFS=$'\t' read -r uuid name startup memory egg_name images; do
    [ -n "$uuid" ] || continue
    memory=${memory:-1024}
    local profile rec reason ooms
    profile=$(perf_detect_profile "$egg_name" "$images" "$startup")
    rec=$(perf_recommend_startup "$profile" "$memory" "$startup")
    ooms=$(perf_recent_ooms "$uuid")
    reason=$(perf_reason_text "$profile" "$ooms")
    jq -nc --arg id "$uuid" --arg n "$name" --arg p "$profile" \
      --arg cur "$startup" --arg rec "$rec" --arg r "$reason" \
      --argjson m "${memory:-1024}" --argjson o "$ooms" \
      '{uuid:$id, name:$n, profile:$p, current_startup:$cur,
        recommended_startup:$rec, reason:$r, memory_mb:$m, recent_ooms:$o}' >> "$lines" 2>/dev/null || true
  done <<EOF
$(mysql -N -B -e "$query" 2>/dev/null)
EOF

  if [ -s "$lines" ]; then
    jq -s '{generated: (now | todate), servers: (map({key: .uuid, value: del(.uuid)}) | from_entries)}' \
      "$lines" > "$PERF_REC_FILE.tmp" 2>/dev/null \
      && chown www-data:www-data "$PERF_REC_FILE.tmp" 2>/dev/null && chmod 644 "$PERF_REC_FILE.tmp" \
      && mv -f "$PERF_REC_FILE.tmp" "$PERF_REC_FILE"
  fi
  rm -f "$lines"

  if [ ! -f "$PERF_APPLIED_FILE" ]; then
    echo '{}' > "$PERF_APPLIED_FILE"
    chmod 600 "$PERF_APPLIED_FILE"
    perf_mirror_applied
  fi
  return 0
}

perf_apply_request() {
  local uuid=$1 profile
  profile=$(cat "$PERF_REQUEST_DIR/perf-$uuid.req" 2>/dev/null || echo "")
  rm -f "$PERF_REQUEST_DIR/perf-$uuid.req"

  local row
  row=$(mysql -N -B -e "SELECT s.startup FROM pelican.servers s WHERE s.uuid='$uuid';" 2>/dev/null)
  if [ -z "$row" ]; then
    echo '{"ok": false, "error": "server not found"}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
    return 0
  fi

  if [ "$profile" = "revert" ]; then
    local original
    original=$(jq -r --arg u "$uuid" '.[$u].original_startup // empty' "$PERF_APPLIED_FILE" 2>/dev/null)
    if [ -z "$original" ]; then
      echo '{"ok": false, "error": "no applied tuning to revert"}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
      return 0
    fi
    mysql -e "UPDATE pelican.servers SET startup='$(perf_sql_escape "$original")' WHERE uuid='$uuid';" 2>>"$INSTALL_LOG"
    jq --arg u "$uuid" 'del(.[$u])' "$PERF_APPLIED_FILE" > "$PERF_APPLIED_FILE.tmp" 2>/dev/null \
      && mv -f "$PERF_APPLIED_FILE.tmp" "$PERF_APPLIED_FILE"
    perf_mirror_applied
    log "Server $uuid: startup reverted to original."
    echo '{"ok": true, "action": "reverted"}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
    return 0
  fi

  local mem cur profile_now chosen rec
  mem=$(mysql -N -B -e "SELECT COALESCE(memory,1024) FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null); mem=${mem:-1024}
  cur=$(mysql -N -B -e "SELECT COALESCE(startup,'') FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null)
  profile_now=$(jq -r --arg u "$uuid" '.servers[$u].profile // "generic"' "$PERF_REC_FILE" 2>/dev/null)
  chosen=${profile:-$profile_now}
  rec=$(perf_recommend_startup "$chosen" "$mem" "$cur")

    jq --arg u "$uuid" --arg p "$chosen" --arg o "$cur" \
    '.[$u] = {profile: $p, original_startup: $o, applied_at: (now | todate)}' \
    "$PERF_APPLIED_FILE" > "$PERF_APPLIED_FILE.tmp" 2>/dev/null \
    && mv -f "$PERF_APPLIED_FILE.tmp" "$PERF_APPLIED_FILE"

  perf_mirror_applied

  mysql -e "UPDATE pelican.servers SET startup='$(perf_sql_escape "$rec")' WHERE uuid='$uuid';" 2>>"$INSTALL_LOG"
  log "Server $uuid: applied '$chosen' tuning (restart the server to take effect)."
  jq -nc --arg s "$rec" '{ok: true, action: "applied", startup: $s}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
  perf_scan
  return 0
}

perfctl_process_requests() {
  [ -d "$PERF_REQUEST_DIR" ] || mkdir -p "$PERF_REQUEST_DIR" 2>/dev/null
  [ -d "$PERF_REQUEST_DIR" ] || return 0
  local req uuid
  for req in "$PERF_REQUEST_DIR"/perf-*.req; do
    [ -e "$req" ] || continue
    uuid=$(basename "$req" .req | sed 's/^perf-//')
    [ -n "$uuid" ] || continue
    perf_apply_request "$uuid"
    chmod 644 "$PERF_REQUEST_DIR/perf-$uuid.result" 2>/dev/null || true
    chown www-data:www-data "$PERF_REQUEST_DIR/perf-$uuid.result" 2>/dev/null || true
  done
  return 0
}

perfctl_phase() {
  banner "Phase 13 - Performance advisor"
  mkdir -p "$PERF_REQUEST_DIR" 2>/dev/null || true
  chown www-data:www-data "$PERF_REQUEST_DIR" 2>/dev/null || true
  perf_scan || true
  perfctl_process_requests
  perf_mirror_applied
  log "Performance advisor ready (recommendations in storage/app/perf-recommendations.json)."
}
