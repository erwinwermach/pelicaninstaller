PERF_REC_FILE="$PANEL_STORAGE/perf-recommendations.json"
PERF_APPLIED_FILE="$PI_ROOT/perf-applied.json"
PERF_BOOT_FILE="$PI_ROOT/boot-cache.json"
PERF_REQUEST_DIR="$PANEL_STORAGE/requests"
PERF_VOLUMES="${PERF_VOLUMES:-/var/lib/pelican/volumes}"
PERF_BACKUP_DIR="${PERF_BACKUP_DIR:-$PANEL_STORAGE/perf-backups}"
PERF_INFRA_RESERVE_LOW_MB="${PERF_INFRA_RESERVE_LOW_MB:-2048}"
PERF_INFRA_RESERVE_HIGH_MB="${PERF_INFRA_RESERVE_HIGH_MB:-3072}"
# UDP ports the voice-chat quick setup allocates from (first free port wins).
VOICE_PORTS="${VOICE_PORTS:-24454-24463}"
PERF_VOICECHAT_PROJECT="${PERF_VOICECHAT_PROJECT:-simple-voice-chat}"
PERF_VOICECHAT_UA="${PERF_VOICECHAT_UA:-pelicaninstaller-perfctl/1.0 (github.com/erwinwermach/pelicaninstaller)}"

perf_profiles_list() {
  cat <<'EOF'
mc-paper|PaperMC/Purpin-style servers: G1 tuning sized to the allocation
mc-fabric|Fabric modded: G1 tuning with larger region size for big heaps
mc-forge|Forge modded: G1 tuning with larger region size
mc-neoforge|NeoForge modded: G1 tuning with larger region size
mc-pumpkin|Pumpkin (Rust server): no JVM flags; pumpkin.toml tuning and a small memory footprint
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
    *pumpkin*) echo mc-pumpkin; return ;;
    *paper*|*purpur*|*pufferfish*|*leaves*) echo mc-paper; return ;;
    *velocity*|*waterfall*|*bungee*) echo proxy-java; return ;;
    *neoforge*) echo mc-neoforge; return ;;
    *quilt*) echo mc-fabric; return ;;
    *fabric*) echo mc-fabric; return ;;
    *forge*) echo mc-forge; return ;;
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

perf_ram_total_mb() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
}

perf_ram_avail_mb() {
  awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
}

perf_core_count() {
  nproc 2>/dev/null || echo 1
}

perf_docker_limit_mb() {
  local uuid=$1 bytes
  bytes=$(docker inspect --format '{{.HostConfig.Memory}}' "$uuid" 2>/dev/null || echo 0)
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  echo $(( bytes / 1048576 ))
}

perf_docker_rss_mb() {
  local uuid=$1 v
  v=$(docker stats --no-stream --format '{{.MemUsage}}' "$uuid" 2>/dev/null | head -1 | awk '{print $1}')
  case "$v" in
    *GiB) awk -v n="${v%GiB}" 'BEGIN{printf "%d", n*1024}' ;;
    *MiB) awk -v n="${v%MiB}" 'BEGIN{printf "%d", n}' ;;
    *KiB) awk -v n="${v%KiB}" 'BEGIN{printf "%d", n/1024}' ;;
    *) echo 0 ;;
  esac
}

perf_restart_count() {
  local n
  n=$(docker inspect --format '{{.RestartCount}}' "$1" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}

perf_cant_keep_up() {
  local uuid=$1 log n
  log="$PERF_VOLUMES/$uuid/logs/latest.log"
  [ -f "$log" ] || { echo 0; return; }
  n=$(grep -c "Can't keep up" "$log" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}

perf_route_ping_ms() {
  local host ms
  [ -f "$PANEL_STORAGE/routes.json" ] || { echo ""; return; }
  host=$(grep -oE '[a-zA-Z0-9][a-zA-Z0-9._-]*\.[a-zA-Z]{2,}' "$PANEL_STORAGE/routes.json" 2>/dev/null \
    | grep -vE '^(localhost|.*\.local)$' | head -1)
  [ -n "$host" ] || { echo ""; return; }
  ms=$(ping -c 2 -W 2 "$host" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%d", $5}' || true)
  echo "$ms"
}

perf_java_flags() {
  local heap=$1
  local region="8M"
  [ "$heap" -ge 12288 ] && region="16M"
    printf -- '-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=%s -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true' "$region"
}

perf_server_image() {
  mysql -N -B -e "SELECT COALESCE(image,'') FROM pelican.servers WHERE uuid='$1';" 2>/dev/null | head -1
}

perf_boot_java_major() {
  printf '%s' "$1" | grep -oE '(java|jdk)[_-]?[0-9]+' | head -1 | grep -oE '[0-9]+' || true
}

perf_boot_profiles_ok() {
  case "$1" in
    mc-paper|mc-fabric|mc-forge|mc-neoforge|mc-generic|proxy-java) return 0 ;;
    *) return 1 ;;
  esac
}

perf_mods_hash() {
  local dir="$PERF_VOLUMES/$1"
  [ -d "$dir" ] || { echo ""; return; }
  ( cd "$dir" 2>/dev/null && find . -maxdepth 3 \( -name '*.jar' -o -name '*.jar.disabled' \) -printf '%P:%s:%T@\n' 2>/dev/null | sort ) \
    | md5sum 2>/dev/null | cut -d' ' -f1
}

perf_boot_state_write() {
  # args: uuid mode [mods_hash]
  local uuid=$1 mode=$2 hash=${3:-}
  [ -f "$PERF_BOOT_FILE" ] || echo '{}' > "$PERF_BOOT_FILE"
  chmod 600 "$PERF_BOOT_FILE" 2>/dev/null || true
  if jq --arg u "$uuid" --arg m "$mode" --arg h "$hash" \
      '.[$u] = ((.[$u] // {}) + {mode:$m, updated_at:(now | todate)}) | if $h != "" then .[$u].mods_hash = $h else . end' \
      "$PERF_BOOT_FILE" > "$PERF_BOOT_FILE.tmp" 2>/dev/null; then
    mv -f "$PERF_BOOT_FILE.tmp" "$PERF_BOOT_FILE" 2>/dev/null || rm -f "$PERF_BOOT_FILE.tmp"
  else
    rm -f "$PERF_BOOT_FILE.tmp" 2>/dev/null
  fi
}

perf_boot_dir_ensure() {
  local dir="$PERF_VOLUMES/$1/.perf"
  mkdir -p "$dir" 2>/dev/null || true
  chown pelican:pelican "$dir" 2>/dev/null || true
}

perf_boot_state() {
  # args: uuid java_major profile [heap_mb]
  # echoes JSON {mode, java_major, eligible_cds, eligible_aot, cache_present, stale, flags, note}
  local uuid=$1 major=$2 profile=$3 heap=${4:-0}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$heap" in ''|*[!0-9]*) heap=0 ;; esac
  local cds=false aot=false
  if perf_boot_profiles_ok "$profile" && [ "$major" -ge 19 ]; then cds=true; fi
  if perf_boot_profiles_ok "$profile" && [ "$major" -ge 25 ] && [ "$heap" -le 8192 ]; then aot=true; fi

  local state mode
  state=$(jq -r --arg u "$uuid" '.[$u].mode // empty' "$PERF_BOOT_FILE" 2>/dev/null)
  case "$state" in
    cds|aot|off) mode=$state ;;
    *) if [ "$cds" = true ]; then mode=cds; else mode=off; fi ;;
  esac
  if [ "$mode" = "cds" ] && [ "$cds" != true ]; then mode=off; fi
  if [ "$mode" = "aot" ] && [ "$aot" != true ]; then mode=off; fi

  local cache=false stale=false flags="" note=""
  if [ "$mode" = "aot" ]; then
    [ -f "$PERF_VOLUMES/$uuid/.perf/app.aot" ] && cache=true
    local cur_hash stored
    cur_hash=$(perf_mods_hash "$uuid")
    stored=$(jq -r --arg u "$uuid" '.[$u].mods_hash // empty' "$PERF_BOOT_FILE" 2>/dev/null)
    if [ "$cache" = true ] && [ -n "$stored" ] && [ -n "$cur_hash" ] && [ "$stored" != "$cur_hash" ]; then
      rm -f "$PERF_VOLUMES/$uuid/.perf/app.aot" 2>/dev/null || true
      cache=false
      stale=true
      perf_boot_state_write "$uuid" aot "$cur_hash"
    fi
    if [ "$cache" = true ]; then
      flags="-XX:AOTCache=.perf/app.aot"
      note="Java 25+ AOT class cache is trained - reused at every boot for faster startup."
    else
      flags="-XX:AOTCacheOutput=.perf/app.aot"
      note="The next Java 25+ startup trains the AOT cache (one restart); later boots reuse it."
    fi
  elif [ "$mode" = "cds" ]; then
    flags="-XX:SharedArchiveFile=.perf/app.jsa -XX:+AutoCreateSharedArchive"
    note="Java class-data-sharing archive is maintained automatically by the JVM - faster class loading, no risk."
  elif [ "$aot" = true ]; then
    note="Java 25+ is the default here; an AOT class cache can cut startup further - opt in from this page."
  fi

  jq -nc --arg m "$mode" --argjson j "$major" --argjson c "$cds" --argjson a "$aot" \
    --argjson p "$cache" --argjson s "$stale" --arg f "$flags" --arg n "$note" \
    '{mode:$m, java_major:$j, eligible_cds:$c, eligible_aot:$a, cache_present:$p, stale:$s, flags:$f, note:$n}'
}

perf_update_startup_db() {
  # args: uuid profile
  # recomputes heap/startup (incl. boot-cache flags) and writes servers.startup + memory
  # echoes JSON {heap_mb, memory_mb, startup, boot_flags}
  local uuid=$1 chosen=$2
  local total_ram avail_ram budget eff rss_sum budget_json mem cur
  total_ram=$(perf_ram_total_mb)
  case "$total_ram" in ''|*[!0-9]*) total_ram=0 ;; esac
  avail_ram=$(perf_ram_avail_mb)
  case "$avail_ram" in ''|*[!0-9]*) avail_ram=0 ;; esac
  eff=$(perf_docker_limit_mb "$uuid")
  rss_sum=$(perf_docker_rss_mb "$uuid")
  budget_json=$(perf_node_budget "$total_ram" "$avail_ram" "$rss_sum")
  budget=$(printf '%s' "$budget_json" | jq -r '.budget_mb')
  mem=$(mysql -N -B -e "SELECT COALESCE(memory,0) FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null); mem=${mem:-0}
  case "$mem" in ''|*[!0-9]*) mem=0 ;; esac
  cur=$(mysql -N -B -e "SELECT COALESCE(startup,'') FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null)

  local mem_json heap recmem boot_json boot_flags rec major
  mem_json=$(perf_recommend_memory "$chosen" "$mem" "$eff" "$budget")
  heap=$(printf '%s' "$mem_json" | jq -r '.recommended_heap_mb')
  recmem=$(printf '%s' "$mem_json" | jq -r '.recommended_memory_mb')
  major=$(perf_boot_java_major "$(perf_server_image "$uuid")")
  boot_json=$(perf_boot_state "$uuid" "$major" "$chosen" "$heap")
  boot_flags=$(printf '%s' "$boot_json" | jq -r '.flags // empty')
  if [ -n "$boot_flags" ]; then perf_boot_dir_ensure "$uuid"; fi
  rec=$(perf_recommend_startup "$chosen" "$heap" "$cur" "$boot_flags")
  mysql -e "UPDATE pelican.servers SET startup='$(perf_sql_escape "$rec")', memory=$recmem WHERE uuid='$uuid';" 2>>"$INSTALL_LOG"
  jq -nc --arg s "$rec" --argjson h "$heap" --argjson m "$recmem" --arg f "$boot_flags" \
    '{heap_mb:$h, memory_mb:$m, startup:$s, boot_flags:$f}'
}

perf_boot_request() {
  # args: uuid raw_json  (op: boot_cache, mode: cds|aot|off)
  local uuid=$1 raw=$2 mode
  mode=$(printf '%s' "$raw" | jq -r '.mode // empty' 2>/dev/null || true)
  case "$mode" in
    cds|aot|off) ;;
    *) perf_write_result "$uuid" '{"ok": false, "error": "invalid boot cache mode"}'; return 0 ;;
  esac

  local image major
  image=$(perf_server_image "$uuid")
  major=$(perf_boot_java_major "$image")
  case "$major" in ''|*[!0-9]*) major=0 ;; esac

  if [ "$mode" = "cds" ] && [ "$major" -lt 19 ]; then
    perf_write_result "$uuid" "{\"ok\": false, \"error\": \"CDS needs Java 19+ (detected: ${major:-unknown})\"}"
    return 0
  fi
  if [ "$mode" = "aot" ]; then
    if [ "$major" -lt 25 ]; then
      perf_write_result "$uuid" "{\"ok\": false, \"error\": \"AOT cache needs Java 25+ (detected: ${major:-unknown})\"}"
      return 0
    fi
    local eff mem base
    eff=$(perf_docker_limit_mb "$uuid")
    mem=$(mysql -N -B -e "SELECT COALESCE(memory,0) FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null); mem=${mem:-0}
    case "$mem" in ''|*[!0-9]*) mem=0 ;; esac
    base=$eff
    [ "$base" -le 0 ] && base=$mem
    if [ "$base" -gt 10240 ]; then
      perf_write_result "$uuid" "{\"ok\": false, \"error\": \"AOT cache creation runs with the same heap twice - on ${base}MB servers stay on CDS\"}"
      return 0
    fi
  fi

  perf_boot_state_write "$uuid" "$mode" "$(perf_mods_hash "$uuid")"
  if [ "$mode" = "off" ]; then
    rm -f "$PERF_VOLUMES/$uuid/.perf/app.jsa" "$PERF_VOLUMES/$uuid/.perf/app.aot" 2>/dev/null || true
  else
    perf_boot_dir_ensure "$uuid"
  fi

  local profile_now upd
  profile_now=$(jq -r --arg u "$uuid" '.[$u].profile // empty' "$PERF_APPLIED_FILE" 2>/dev/null)
  if [ -n "$profile_now" ]; then
    upd=$(perf_update_startup_db "$uuid" "$profile_now")
    perf_write_result "$uuid" "$(jq -nc --arg m "$mode" \
      --arg s "$(printf '%s' "$upd" | jq -r '.startup // empty')" \
      '{ok: true, action: "boot_cache", mode: $m, startup: $s, restart_required: true}')"
  else
    perf_write_result "$uuid" "$(jq -nc --arg m "$mode" '{ok: true, action: "boot_cache", mode: $m, restart_required: false}')"
  fi
  perf_scan
  return 0
}

perf_recommend_startup() {
  local profile=$1 heap=$2 startup=$3 boot_flags=${4:-}
  local cleaned flags
  case "$profile" in
    mc-paper|mc-fabric|mc-forge|mc-neoforge|mc-generic)
      flags=$(perf_java_flags "$heap")
      if [ "$profile" = "mc-paper" ]; then
        flags="$flags -DPaper.IgnoreJavaVersion=true"
      fi
      [ -n "$boot_flags" ] && flags="$flags $boot_flags"
      cleaned=$(printf '%s' "$startup" | tr ' ' '\n' | grep -vE '^-(Xms|Xmx|XX:)' | paste -sd' ')
      if printf '%s' "$cleaned" | grep -qiE '(^|[[:space:]])java([[:space:]]|$)'; then
        printf '%s' "$cleaned" | sed -E "s|(java[[:space:]])|\\1-Xms${heap}M -Xmx${heap}M $flags |"
      else
        printf 'java -Xms%sM -Xmx%sM %s %s' "$heap" "$heap" "$flags" "$cleaned"
      fi
      ;;
    proxy-java)
      [ "$heap" -gt 2048 ] && heap=2048
      [ -n "$boot_flags" ] && flags="$boot_flags"
      cleaned=$(printf '%s' "$startup" | tr ' ' '\n' | grep -vE '^-(Xms|Xmx|XX:)' | paste -sd' ')
      if printf '%s' "$cleaned" | grep -qiE '(^|[[:space:]])java([[:space:]]|$)'; then
        printf '%s' "$cleaned" | sed -E "s|(java[[:space:]])|\\1-Xms${heap}M -Xmx${heap}M -XX:+UseG1GC -XX:G1HeapRegionSize=4M -XX:+ParallelRefProcEnabled ${flags:-} |"
      else
        printf 'java -Xms%sM -Xmx%sM %s %s' "$heap" "$heap" "-XX:+UseG1GC -XX:G1HeapRegionSize=4M -XX:+ParallelRefProcEnabled" "${flags:-}"
      fi
      ;;
    source-engine)
      printf '%s -nobreakpad -novid' "${startup% }"
      ;;
    python)
      printf 'PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 %s' "$startup"
      ;;
    nodejs)
      printf '%s --max-old-space-size=%s' "${startup% }" "$heap"
      ;;
    *)
      printf '%s' "$startup"
      ;;
  esac
}

perf_profile_heap_floor_mb() {
  case "$1" in
    mc-forge|mc-fabric|mc-neoforge) echo 4096 ;;
    mc-paper) echo 2560 ;;
    mc-pumpkin) echo 512 ;;
    mc-generic) echo 1024 ;;
    proxy-java) echo 1024 ;;
    *) echo 512 ;;
  esac
}

perf_profile_overhead_mb() {
  case "$1" in
    mc-forge|mc-fabric|mc-neoforge) echo 1792 ;;
    mc-paper) echo 1280 ;;
    mc-pumpkin) echo 256 ;;
    mc-generic) echo 1024 ;;
    proxy-java) echo 640 ;;
    *) echo 384 ;;
  esac
}

perf_node_budget() {
  # args: total_ram avail_ram game_rss_sum
  # echoes JSON {reserve_mb, budget_mb}; reserve = measured non-game usage + safety margin
  local total=$1 avail=$2 gamerss=$3
  local used=$(( total - avail ))
  local reserve=$(( used - gamerss ))
  [ "$reserve" -lt 1024 ] && reserve=1024
  reserve=$(( reserve + 256 ))
  local budget=$(( total - reserve ))
  [ "$budget" -lt 1024 ] && budget=1024
  jq -nc --argjson r "$reserve" --argjson b "$budget" '{reserve_mb:$r, budget_mb:$b}'
}

perf_recommend_memory() {
  # args: profile panel_mem effective_limit_mb budget_mb
  # echoes JSON: {recommended_heap_mb, recommended_memory_mb, unbounded, note}
  local profile=$1 panel=$2 eff=$3 budget=$4
  local floor overhead maxheap desired heap note="" unbounded=false
  floor=$(perf_profile_heap_floor_mb "$profile")
  overhead=$(perf_profile_overhead_mb "$profile")
  maxheap=$(( budget - overhead ))
  [ "$maxheap" -lt 512 ] && maxheap=512

  if [ "$profile" = "mc-pumpkin" ]; then
    local base=$eff
    [ "$base" -le 0 ] && base=$panel
    if [ "$base" -le 0 ]; then
      heap=512
      note="Pumpkin (Rust) has no JVM - the native footprint is tiny. A ~512MB allocation keeps the host overcommit-safe."
    else
      heap=$(( base / 4 ))
      [ "$heap" -lt 256 ] && heap=256
      [ "$heap" -gt 1024 ] && heap=1024
      note="Pumpkin needs only a fraction of a Java server's memory - the allocation can shrink to ~${heap}MB."
    fi
    if [ "$heap" -gt "$maxheap" ]; then
      heap=$maxheap
      note="$note Capped to what the host budget (${budget}MB) can hold."
    fi
    heap=$(( heap / 64 * 64 ))
    [ "$heap" -lt 256 ] && heap=256
    local precmem=$(( heap + overhead ))
    precmem=$(( precmem / 64 * 64 ))
    jq -nc --argjson h "$heap" --argjson m "$precmem" --argjson u false --arg n "$note" \
      '{recommended_heap_mb:$h, recommended_memory_mb:$m, unbounded:$u, note:$n}'
    return 0
  fi

  heap=0; desired=0
  if [ "$eff" -gt 0 ]; then
    desired=$(( eff - eff / 5 ))
    note="Heap sized to 80% of the container limit (${eff}MB)."
  elif [ "$panel" -gt 0 ] && [ "$panel" -ge 512 ]; then
    desired=$(( panel - panel / 5 ))
    note="Heap sized to 80% of the panel allocation (${panel}MB)."
  else
    unbounded=true
    desired=$floor
    note="No memory limit is set for this server (allocation 0 and no container limit); the JVM sizes its heap from the whole host. An explicit cap is recommended."
  fi
  heap=$desired
  if [ "$heap" -lt "$floor" ] && [ "$maxheap" -ge "$floor" ]; then
    heap=$floor
    note="${note}Raised to the ${profile} workload floor (${floor}MB)."
  fi
  if [ "$heap" -gt "$maxheap" ]; then
    heap=$maxheap
    note="${note} Capped to what the host budget (${budget}MB) can hold with the ${profile} native overhead (~${overhead}MB) - the host is below this workload's floor."
  fi
  heap=$(( heap / 256 * 256 ))
  [ "$heap" -lt 256 ] && heap=256
  local recmem=$(( heap + overhead ))
  recmem=$(( recmem / 256 * 256 ))
  jq -nc --argjson h "$heap" --argjson m "$recmem" --argjson u "$unbounded" --arg n "$note" \
    '{recommended_heap_mb:$h, recommended_memory_mb:$m, unbounded:$u, note:$n}'
}

perf_prop_current() {
  local file=$1 key=$2
  grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-
}

perf_recommend_server_props() {
  # args: profile volume_dir avail_mb load1 cores cant_keep_up
  # echoes JSON {key: {current, recommended, reason}} for keys that should change
  local profile=$1 dir=$2 avail=$3 load1=$4 cores=$5 keepup=$6
  local file="$dir/server.properties"
  local out="{}" cur rec reason
  [ -f "$file" ] || { echo "{}"; return; }
  add_rec() {
    local key=$1 cur=$2 rec=$3 reason=$4
    [ "$cur" = "$rec" ] && return 0
    out=$(jq -c --arg k "$key" --arg c "$cur" --arg r "$rec" --arg w "$reason" \
      '. + {($k): {current: $c, recommended: $r, reason: $w}}' <<<"$out")
  }
  local pressure=false
  if [ "$avail" -lt 1024 ] || [ "$keepup" -ge 3 ]; then pressure=true; fi

  case "$profile" in
    mc-paper|mc-fabric|mc-forge|mc-neoforge|mc-generic|generic)
      cur=$(perf_prop_current "$file" sync-chunk-writes)
      add_rec sync-chunk-writes "$cur" "false" "Chunk saves moved off the main tick loop (recommended for non-Paper servers)."
      if [ "$pressure" = true ]; then
        cur=$(perf_prop_current "$file" view-distance)
        if [ -n "$cur" ] && [ "$cur" -gt 6 ] 2>/dev/null; then
          add_rec view-distance "$cur" "6" "Host memory/CPU pressure detected - lower view distance keeps TPS stable."
        fi
        cur=$(perf_prop_current "$file" simulation-distance)
        if [ -n "$cur" ] && [ "$cur" -gt 6 ] 2>/dev/null; then
          add_rec simulation-distance "$cur" "6" "Reduces per-tick entity and crop simulation cost on a strained host."
        fi
      fi
      cur=$(perf_prop_current "$file" network-compression-threshold)
      add_rec network-compression-threshold "${cur:-256}" "64" "Compresses more packets - noticeably better latency for players on slow or tunneled connections."
      cur=$(perf_prop_current "$file" entity-broadcast-range-percentage)
      if [ -n "$cur" ] && [ "$cur" -gt 75 ] 2>/dev/null; then
        add_rec entity-broadcast-range-percentage "$cur" "75" "Cuts outgoing entity packets; rarely noticeable in gameplay."
      fi
      ;;
  esac
  echo "$out"
}

perf_recommend_jvm_args() {
  # args: profile volume_dir heap_mb
  local profile=$1 dir=$2 heap=$3
  local file="$dir/user_jvm_args.txt" cur rec present=false
  case "$profile" in
    mc-paper|mc-fabric|mc-forge|mc-neoforge|mc-generic) ;;
    *) echo '{}'; return ;;
  esac
  if [ -f "$file" ]; then
    present=true
    cur=$(grep -E '^-Xm[sx][0-9]' "$file" 2>/dev/null | paste -sd' ' || true)
  else
    cur=""
  fi
  rec="-Xms${heap}M -Xmx${heap}M"
  jq -nc --argjson p "$present" --arg c "$cur" --arg r "$rec" \
    '{present:$p, current:$c, recommended:$r}'
}

perf_toml_current() {
  local file=$1 section=$2 key=$3
  [ -f "$file" ] || return 0
  awk -v sect="$section" -v key="$key" '
    /^\[/ { insec = ($0 ~ ("^\\[" sect "\\]")) }
    insec && $0 ~ ("^" key "[ \t]*=") { sub(/^[^=]*=[ \t]*/, ""); print; exit }
  ' "$file" 2>/dev/null
}

perf_set_toml_key() {
  local file=$1 section=$2 key=$3 val=$4 tmp
  [ -f "$file" ] || return 1
  tmp=$(mktemp)
  awk -v sect="$section" -v key="$key" -v val="$val" '
    /^\[/ { insec = ($0 ~ ("^\\[" sect "\\]")) }
    {
      if (insec && !done && $0 ~ ("^" key "[ \t]*=")) { print key " = " val; done=1; next }
      print
    }
    END { if (!done) exit 3 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

perf_recommend_pumpkin_toml() {
  # args: volume_dir avail_mb cant_keep_up ping_ms
  # echoes JSON {key: {current, recommended, reason}} for pumpkin.toml (report-only + apply-capable)
  local dir=$1 avail=${2:-0} keepup=${3:-0} ping=${4:-}
  local file="$dir/pumpkin.toml"
  local out="{}" cur rec
  [ -f "$file" ] || { echo "{}"; return; }
  add_rec() {
    local key=$1 cur=$2 rec=$3 reason=$4
    [ -n "$cur" ] || return 0
    [ "$cur" = "$rec" ] && return 0
    out=$(jq -c --arg k "$key" --arg c "$cur" --arg r "$rec" --arg w "$reason" \
      '. + {($k): {current: $c, recommended: $r, reason: $w}}' <<<"$out")
  }
  local pressure=false
  if [ "$avail" -lt 1024 ] || [ "$keepup" -ge 3 ]; then pressure=true; fi

  if [ "$pressure" = true ]; then
    cur=$(perf_toml_current "$file" "networking.java" "view_distance")
    case "$cur" in ''|*[!0-9]*) ;; *) if [ "$cur" -gt 10 ]; then
      add_rec "networking.java.view_distance" "$cur" "10" "Host memory/CPU pressure - Pumpkin scales better with a tighter view distance."
    fi ;; esac
    cur=$(perf_toml_current "$file" "networking.java" "simulation_distance")
    case "$cur" in ''|*[!0-9]*) ;; *) if [ "$cur" -gt 8 ]; then
      add_rec "networking.java.simulation_distance" "$cur" "8" "Reduces per-tick simulation cost on a strained host."
    fi ;; esac
  fi
  if [ -n "$ping" ] && [ "$ping" -ge 80 ]; then
    cur=$(perf_toml_current "$file" "networking.java.compression" "threshold")
    case "$cur" in ''|*[!0-9]*) ;; *) if [ "$cur" -gt 128 ]; then
      add_rec "networking.java.compression.threshold" "$cur" "128" "Tunneled/slow links: compress more packets to cut latency spikes."
    fi ;; esac
  fi
  cur=$(perf_toml_current "$file" "world.chunk.compression" "algorithm")
  if [ -n "$cur" ] && [ "$cur" != '"LZ4"' ]; then
    add_rec "world.chunk.compression.algorithm" "$cur" '"LZ4"' "LZ4 chunk compression is dramatically cheaper to save/load than ZLib."
  fi
  echo "$out"
}

perf_apply_pumpkin_toml() {
  # args: uuid volume_dir recs_json
  # echoes JSON array of applied file names
  local uuid=$1 dir=$2 recs=$3
  local file="$dir/pumpkin.toml"
  [ -f "$file" ] || { echo "[]"; return; }
  [ "$recs" != "{}" ] || { echo "[]"; return; }
  [ -n "$recs" ] || { echo "[]"; return; }
  perf_backup_file "$uuid" "$file" >/dev/null
  echo "$recs" | jq -r 'to_entries[] | [.key, .value.recommended] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r key rec; do
        [ -n "$key" ] || continue
        perf_set_toml_key "$file" "${key%.*}" "${key##*.}" "$rec" || true
      done
  chown pelican:pelican "$file" 2>/dev/null || true
  echo '["pumpkin.toml"]'
}

perf_detect_yaml_configs() {
  # report-only detection of Paper/Spigot-style configs
  local dir=$1 out="{}" f key
  for key in spigot.yml config/paper-global.yml config/paper-world-defaults.yml purpur.yml bukkit.yml; do
    f="$dir/$key"
    if [ -f "$f" ]; then
      out=$(jq -c --arg k "$key" '. + {($k): true}' <<<"$out")
    fi
  done
  echo "$out"
}

perf_reason_text() {
  local profile=$1 ooms=$2
  local base
  case "$profile" in
    mc-paper) base="PaperMC detected - G1 garbage collector tuned for low pause times." ;;
    mc-fabric) base="Fabric server detected - G1 tuned for modded workloads." ;;
    mc-forge) base="Forge server detected - G1 tuned for modded workloads." ;;
    mc-neoforge) base="NeoForge server detected - G1 tuned for modded workloads." ;;
    mc-pumpkin) base="Pumpkin (Rust server) detected - no JVM tuning needed; it runs with a small native footprint." ;;
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

perf_platform_advice() {
  # args: profile volume_dir egg_name
  # echoes JSON {verdict, current, suggested, experimental, summary, reasons[], blockers[]}
  local profile=$1 dir=$2
  local verdict="stay" current="unknown" suggested="" experimental=false summary="" reasons blockers
  local has_plugins=false
  if [ -n "$dir" ] && ls "$dir/plugins"/*.jar >/dev/null 2>&1; then
    has_plugins=true
  fi

  case "$profile" in
    mc-pumpkin)
      current="Pumpkin (Rust)"; suggested="Pumpkin"
      summary="Already on the leanest platform for vanilla-style hosting: native Rust, tiny footprint, instant boot."
      reasons=$(jq -nc --arg a "No JVM overhang and a fraction of the RAM a Java server needs." --arg b "Java and Bedrock clients share one world." '[$a,$b]')
      blockers=$(jq -nc --arg a "Pre-release software: keep backups and expect some vanilla mechanics to be incomplete." --arg b "Only the newest Anvil world format is supported." '[$a,$b]')
      ;;
    mc-paper)
      current="Paper-family (Java)"
      if [ "$has_plugins" = true ]; then
        suggested="stay on Paper/Purpur"
        summary="Plugins are in use - Paper/Purpur is the right platform and cannot be swapped for Pumpkin."
        reasons=$(jq -nc --arg a "Paper-family plugins only run on Bukkit-based servers." --arg b "The tuned JVM/GC bundle here already covers the Java overhead." '[$a,$b]')
        blockers=$(jq -nc '[]')
      else
        verdict="consider-pumpkin"
        suggested="Pumpkin (experimental) for new worlds, Paper/Purpur for existing ones"
        summary="No plugins detected: a vanilla-style server can often run on Pumpkin with far less RAM and a much faster boot."
        reasons=$(jq -nc --arg a "Native Rust server boots in milliseconds and uses a fraction of the memory." --arg b "Java and Bedrock clients can join the same world." '[$a,$b]')
        blockers=$(jq -nc --arg a "Pumpkin is pre-release: some mechanics are incomplete and worlds may break between versions." --arg b "World imports only work for the newest Anvil format - never migrate an existing world without a backup." '[$a,$b]')
      fi
      ;;
    mc-generic)
      verdict="consider-pumpkin"
      current="Vanilla Java"
      suggested="Pumpkin (experimental) for new worlds, Paper/Purpur for existing worlds"
      summary="Vanilla Java servers are exactly what Pumpkin targets: same clients, a fraction of the resources."
      reasons=$(jq -nc --arg a "No JVM, no GC pauses, instant startup." --arg b "Run several small worlds for the memory budget of one Java server." '[$a,$b]')
      blockers=$(jq -nc --arg a "Pumpkin is pre-release: some mechanics and entity behavior are incomplete." --arg b "Anvil import works only for the newest format; keep backups." '[$a,$b]')
      ;;
    mc-fabric|mc-forge|mc-neoforge)
      verdict="stay-modded"
      current="Modded (${profile#mc-})"
      suggested="stay modded"
      summary="Forge/Fabric/NeoForge mods are Java code attached to Mojang's classes and cannot run on Pumpkin - optimization instead comes from server-side performance mods and the JVM boot cache."
      reasons=$(jq -nc --arg a "Mod loaders are architecturally incompatible with Pumpkin (Rust, own plugin API)." --arg b "The optimizer-mod bundle (ModernFix, FerriteCore, ...) is the real boot/performance lever here." '[$a,$b]')
      blockers=$(jq -nc --arg a "Switching platforms would break the modpack." '[$a]')
      ;;
    proxy-java)
      current="Java proxy"; suggested="stay"
      summary="Proxies are cheap and stable on Java; nothing to migrate."
      reasons=$(jq -nc '[]')
      blockers=$(jq -nc '[]')
      ;;
    *)
      current="$profile"; suggested="stay"
      summary=""
      reasons=$(jq -nc '[]')
      blockers=$(jq -nc '[]')
      ;;
  esac

  [ "$verdict" = "consider-pumpkin" ] && experimental=true

  jq -nc --arg v "$verdict" --arg c "$current" --arg s "$suggested" --argjson e "$experimental" \
    --arg m "$summary" --argjson r "$reasons" --argjson b "$blockers" \
    '{verdict:$v, current:$c, suggested:$s, experimental:$e, summary:$m, reasons:$r, blockers:$b}'
}

perf_recent_ooms() {
  local uuid=$1
  [ -f "$PANEL_STORAGE/crashlog/index-server-$uuid.json" ] || { echo 0; return; }
  jq --arg u "$uuid" '[.events[]? | select((.oom // false))] | length' \
    "$PANEL_STORAGE/crashlog/index-server-$uuid.json" 2>/dev/null || echo 0
}

perf_set_prop() {
  local file=$1 key=$2 val=$3
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${val}/" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

perf_set_jvm_args() {
  local file=$1 heap=$2
  sed -i -E '/^-Xm[sx][0-9]/d' "$file" 2>/dev/null || true
  [ -n "$(tail -c 1 "$file" 2>/dev/null)" ] && printf '\n' >> "$file"
  printf -- '-Xms%sM\n-Xmx%sM\n' "$heap" "$heap" >> "$file"
}

perf_backup_file() {
  local uuid=$1 file=$2 dest
  dest="$PERF_BACKUP_DIR/$uuid/$(basename "$file")"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  [ -f "$dest" ] || cp -p "$file" "$dest" 2>/dev/null || true
  echo "$dest"
}

perf_restore_file() {
  local uuid=$1 name=$2 backup file
  backup="$PERF_BACKUP_DIR/$uuid/$name"
  file="$PERF_VOLUMES/$uuid/$name"
  if [ -f "$backup" ]; then
    cp -p "$backup" "$file" 2>/dev/null || true
    chown pelican:pelican "$file" 2>/dev/null || true
  fi
}

perf_apply_files() {
  # args: uuid volume_dir props_json heap
  # echoes JSON ["server.properties", "user_jvm_args.txt", ...]
  local uuid=$1 dir=$2 props=$3 heap=$4
  local applied="[]" f
  f="$dir/server.properties"
  if [ -f "$f" ] && [ "$props" != "{}" ]; then
    perf_backup_file "$uuid" "$f" >/dev/null
    echo "$props" | jq -r 'to_entries[] | [.key, .value.recommended] | @tsv' 2>/dev/null \
      | while IFS=$'\t' read -r key rec; do
          [ -n "$key" ] || continue
          perf_set_prop "$f" "$key" "$rec"
        done
    chown pelican:pelican "$f" 2>/dev/null || true
    applied=$(jq -nc --argjson a "$applied" --arg p "server.properties" '$a + [$p]')
  fi
  f="$dir/user_jvm_args.txt"
  if [ -f "$f" ]; then
    perf_backup_file "$uuid" "$f" >/dev/null
    perf_set_jvm_args "$f" "$heap"
    chown pelican:pelican "$f" 2>/dev/null || true
    applied=$(jq -nc --argjson a "$applied" --arg p "user_jvm_args.txt" '$a + [$p]')
  fi
  echo "$applied"
}

perf_restore_files() {
  # args: uuid files_json (array of relative names)
  local uuid=$1 files=$2 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    perf_restore_file "$uuid" "$f"
  done < <(echo "$files" | jq -r '.[]' 2>/dev/null)
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

  local total_ram avail_ram cores load1 load5 load15 infra_reserve budget
  total_ram=$(perf_ram_total_mb)
  case "$total_ram" in ''|*[!0-9]*) total_ram=0 ;; esac
  avail_ram=$(perf_ram_avail_mb)
  case "$avail_ram" in ''|*[!0-9]*) avail_ram=0 ;; esac
  cores=$(perf_core_count)
  load1=0; load5=0; load15=0
  read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || true
  load1=${load1:-0}; load5=${load5:-0}; load15=${load15:-0}
  infra_reserve=$PERF_INFRA_RESERVE_LOW_MB
  [ "$total_ram" -gt 6144 ] && infra_reserve=$PERF_INFRA_RESERVE_HIGH_MB
  budget=$(( total_ram - infra_reserve ))
  [ "$budget" -lt 1024 ] && budget=1024

  local ping_ms
  ping_ms=$(perf_route_ping_ms)

  local rows
  rows=$(mktemp)
  local query="SELECT s.uuid, COALESCE(s.name,''), COALESCE(s.startup,''), COALESCE(s.memory,0), COALESCE(e.name,''), COALESCE(e.docker_images,''), COALESCE(s.image,'') FROM pelican.servers s LEFT JOIN pelican.eggs e ON s.egg_id = e.id WHERE s.uuid IS NOT NULL;"
  mysql -N -B -e "$query" 2>/dev/null > "$rows" || true
  if [ ! -s "$rows" ]; then
    # older panel schemas without servers.image
    query="SELECT s.uuid, COALESCE(s.name,''), COALESCE(s.startup,''), COALESCE(s.memory,0), COALESCE(e.name,''), COALESCE(e.docker_images,''), '' FROM pelican.servers s LEFT JOIN pelican.eggs e ON s.egg_id = e.id WHERE s.uuid IS NOT NULL;"
    mysql -N -B -e "$query" 2>/dev/null > "$rows" || true
  fi

  local rss_sum=0 uuid_r
  while IFS=$'\t' read -r uuid_r _ _ _ _ _ _; do
    [ -n "$uuid_r" ] || continue
    rss_sum=$(( rss_sum + $(perf_docker_rss_mb "$uuid_r") ))
  done < "$rows"

  local budget_json infra_reserve budget
  budget_json=$(perf_node_budget "$total_ram" "$avail_ram" "$rss_sum")
  infra_reserve=$(printf '%s' "$budget_json" | jq -r '.reserve_mb')
  budget=$(printf '%s' "$budget_json" | jq -r '.budget_mb')

  local sum_allocated=0 sum_recommended=0 server_count=0 no_mem_list=""
  # read-loop vars must be local: a non-local `name` would clobber run_phase's
  # dynamically-scoped local and the stage marker would be written as "".
  local uuid name startup memory egg_name images image

  while IFS=$'\t' read -r uuid name startup memory egg_name images image; do
    [ -n "$uuid" ] || continue
    memory=${memory:-0}
    case "$memory" in ''|*[!0-9]*) memory=0 ;; esac
    if [ "$memory" -eq 0 ]; then
      # A 0 MB limit cannot start: wings sets --memory-swap from it and docker
      # refuses ("set the Memory limit when using Memoryswap limit").
      no_mem_list="${no_mem_list}${no_mem_list:+, }$name"
    fi
    local profile rec reason ooms mem_json heap recmem unb mnote
    local eff rss restarts keepup props jvms yamlc pumpkin slow
    local boot_json boot_mode boot_flags upd mods advice
    local vc_installed vc_port vc_json
    profile=$(perf_detect_profile "$egg_name" "$images" "$startup")
    eff=$(perf_docker_limit_mb "$uuid")
    rss=$(perf_docker_rss_mb "$uuid")
    restarts=$(perf_restart_count "$uuid")
    keepup=$(perf_cant_keep_up "$uuid")
    mem_json=$(perf_recommend_memory "$profile" "$memory" "$eff" "$budget")
    heap=$(printf '%s' "$mem_json" | jq -r '.recommended_heap_mb')
    recmem=$(printf '%s' "$mem_json" | jq -r '.recommended_memory_mb')
    unb=$(printf '%s' "$mem_json" | jq -r '.unbounded')
    mnote=$(printf '%s' "$mem_json" | jq -r '.note')
    boot_json=$(perf_boot_state "$uuid" "$(perf_boot_java_major "$image")" "$profile" "$heap")
    boot_mode=$(printf '%s' "$boot_json" | jq -r '.mode // "off"')
    boot_flags=$(printf '%s' "$boot_json" | jq -r '.flags // empty')
    # AOT opt-in: once the training run produced a cache, switch the applied
    # startup from "train" to "use" automatically (the admin opted in already).
    if [ "$boot_mode" = "aot" ] \
       && [ "$(printf '%s' "$boot_json" | jq -r '.cache_present // false')" = "true" ] \
       && printf '%s' "$startup" | grep -q 'AOTCacheOutput' \
       && [ -f "$PERF_APPLIED_FILE" ] \
       && jq -e --arg u "$uuid" '.[$u] != null' "$PERF_APPLIED_FILE" >/dev/null 2>&1; then
      upd=$(perf_update_startup_db "$uuid" "$profile")
      startup=$(printf '%s' "$upd" | jq -r '.startup // empty')
      boot_flags=$(printf '%s' "$upd" | jq -r '.boot_flags // empty')
      log "Server $uuid: AOT cache trained - startup switched to cached class loading."
    fi
    rec=$(perf_recommend_startup "$profile" "$heap" "$startup" "$boot_flags")
    ooms=$(perf_recent_ooms "$uuid")
    reason=$(perf_reason_text "$profile" "$ooms")
    props=$(perf_recommend_server_props "$profile" "$PERF_VOLUMES/$uuid" "$avail_ram" "$load1" "$cores" "$keepup")
    jvms=$(perf_recommend_jvm_args "$profile" "$PERF_VOLUMES/$uuid" "$heap")
    yamlc=$(perf_detect_yaml_configs "$PERF_VOLUMES/$uuid")
    pumpkin=$(perf_recommend_pumpkin_toml "$PERF_VOLUMES/$uuid" "$avail_ram" "$keepup" "$ping_ms")
    mods='{}'
    if command -v modopt_scan >/dev/null 2>&1; then
      mods=$(modopt_scan "$uuid" "$profile" 2>/dev/null) || mods='{}'
      case "$mods" in \{*) ;; *) mods='{}' ;; esac
    fi
    advice=$(perf_platform_advice "$profile" "$PERF_VOLUMES/$uuid" "$egg_name")
    vc_installed=false
    if compgen -G "$PERF_VOLUMES/$uuid/mods/voicechat-*" >/dev/null 2>&1 \
       || compgen -G "$PERF_VOLUMES/$uuid/plugins/voicechat-*" >/dev/null 2>&1; then
      vc_installed=true
    fi
    vc_port=$(sed -n 's/^port=//p' "$PERF_VOLUMES/$uuid/config/voicechat/voicechat-server.properties" 2>/dev/null | head -1)
    [ -n "$vc_port" ] || vc_port=$(sed -n 's/^port=//p' "$PERF_VOLUMES/$uuid/plugins/voicechat/voicechat-server.properties" 2>/dev/null | head -1)
    vc_json=$(jq -nc --argjson i "$vc_installed" --arg p "$vc_port" \
      '{installed:$i, port:(if $p == "" then null else ($p|tonumber? // null) end)}' 2>/dev/null) || vc_json='{"installed":false,"port":null}'
    slow=false
    if [ -n "$ping_ms" ] && [ "$ping_ms" -ge 80 ] 2>/dev/null; then slow=true; fi
    if [ "$avail_ram" -lt 1024 ]; then slow=true; fi
    server_count=$((server_count + 1))
    sum_allocated=$((sum_allocated + memory))
    sum_recommended=$((sum_recommended + recmem))
    jq -nc --arg id "$uuid" --arg n "$name" --arg p "$profile" \
      --arg cur "$startup" --arg rec "$rec" --arg r "$reason" \
      --argjson m "$memory" --argjson o "$ooms" \
      --argjson eff "$eff" --argjson rss "$rss" \
      --argjson recmem "$recmem" --argjson heap "$heap" --argjson unb "$unb" --arg mn "$mnote" \
      --argjson rst "$restarts" --argjson kpu "$keepup" \
      --argjson pr "$props" --argjson jv "$jvms" --argjson ym "$yamlc" --argjson pkt "$pumpkin" \
      --argjson bc "$boot_json" --argjson mo "$mods" --argjson pa "$advice" \
      --argjson vc "$vc_json" \
      --argjson ping "${ping_ms:-null}" --argjson slow "$slow" \
      '{uuid:$id, name:$n, profile:$p, current_startup:$cur,
        recommended_startup:$rec, reason:$r, memory_mb:$m, recent_ooms:$o,
        effective_limit_mb:$eff, rss_mb:$rss,
        recommended_memory_mb:$recmem, recommended_heap_mb:$heap,
        unbounded:$unb, mem_note:$mn,
        restart_count:$rst, cant_keep_up_count:$kpu,
        boot_cache:$bc, platform_advice:$pa, voicechat:$vc,
        file_recs:{"server.properties":$pr, user_jvm_args:$jv, yaml_configs:$ym, "pumpkin.toml":$pkt, optimizer_mods:$mo},
        network:{ping_ms:(if $ping == null then null else $ping end), slow_link:$slow}}' >> "$lines" 2>/dev/null || true
  done < "$rows"
  rm -f "$rows"

  local over=false
  [ "$sum_recommended" -gt "$budget" ] && over=true
  local node_json
  node_json=$(jq -nc \
    --argjson t "$total_ram" --argjson used "$(( total_ram - avail_ram ))" --argjson avail "$avail_ram" \
    --argjson cores "$cores" --argjson l1 "$load1" --argjson l5 "$load5" --argjson l15 "$load15" \
    --argjson infra "$infra_reserve" --argjson budget "$budget" \
    --argjson sc "$server_count" --argjson sa "$sum_allocated" --argjson sr "$sum_recommended" \
    --argjson over "$over" \
    '{total_ram_mb:$t, used_mb:$used, available_mb:$avail, cores:$cores,
      load1:$l1, load5:$l5, load15:$l15, infra_reserve_mb:$infra, budget_mb:$budget,
      server_count:$sc, sum_allocated_mb:$sa, sum_recommended_mb:$sr, overcommitted:$over}')

  if [ -s "$lines" ]; then
    jq -s --argjson node "$node_json" \
      '{generated: (now | todate), node: $node, servers: (map({key: .uuid, value: del(.uuid)}) | from_entries)}' \
      "$lines" > "$PERF_REC_FILE.tmp" 2>/dev/null \
      && chown www-data:www-data "$PERF_REC_FILE.tmp" 2>/dev/null && chmod 644 "$PERF_REC_FILE.tmp" \
      && mv -f "$PERF_REC_FILE.tmp" "$PERF_REC_FILE"
  else
    jq -nc --argjson node "$node_json" '{generated: (now | todate), node: $node, servers: {}}' \
      > "$PERF_REC_FILE.tmp" 2>/dev/null \
      && chown www-data:www-data "$PERF_REC_FILE.tmp" 2>/dev/null && chmod 644 "$PERF_REC_FILE.tmp" \
      && mv -f "$PERF_REC_FILE.tmp" "$PERF_REC_FILE"
  fi
  rm -f "$lines"

  if [ ! -f "$PERF_APPLIED_FILE" ]; then
    echo '{}' > "$PERF_APPLIED_FILE"
    chmod 600 "$PERF_APPLIED_FILE"
    perf_mirror_applied
  fi

  if [ -n "$no_mem_list" ]; then
    log_err "Server(s) without a memory limit cannot start: $no_mem_list - wings/docker refuse a memory-swap limit without memory. Set a memory limit in the panel (4-6 GB is typical for modpacks)."
  fi
  return 0
}

perf_write_result() {
  local uuid=$1 json=$2
  local tmp="$PERF_REQUEST_DIR/.perf-$uuid.result.tmp.$$"
  printf '%s\n' "$json" > "$tmp" 2>/dev/null || return 0
  chmod 644 "$tmp" 2>/dev/null || true
  chown www-data:www-data "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$PERF_REQUEST_DIR/perf-$uuid.result" 2>/dev/null || rm -f "$tmp"
}

# ------------------------------------------------------------------
# Simple Voice Chat quick setup
# ------------------------------------------------------------------

perf_server_field() {
  # $2 = env variable name (MC_VERSION/SERVER_JARFILE/LOADER_VERSION) or a
  # servers column name.
  local uuid=$1 col=$2
  case "$col" in
    MC_VERSION|SERVER_JARFILE|LOADER_VERSION)
      mysql -N -B -e "SELECT sv.variable_value FROM pelican.egg_variables ev JOIN pelican.server_variables sv ON sv.variable_id=ev.id JOIN pelican.servers s ON s.id=sv.server_id WHERE s.uuid='$uuid' AND ev.env_variable='$col';" 2>/dev/null | head -1
      ;;
    *)
      mysql -N -B -e "SELECT $col FROM pelican.servers s WHERE s.uuid='$uuid';" 2>/dev/null | head -1
      ;;
  esac
}

perf_voice_port_range() {
  local spec="$VOICE_PORTS" lo hi
  case "$spec" in
    *-*) lo=${spec%-*}; hi=${spec#*-} ;;
    *) lo=$spec; hi=$spec ;;
  esac
  case "$lo" in ''|*[!0-9]*) lo=24454 ;; esac
  case "$hi" in ''|*[!0-9]*) hi=$lo ;; esac
  [ "$hi" -ge "$lo" ] || hi=$lo
  echo "$lo $hi"
}

perf_voice_port_allocate() {
  # Allocates (or reuses) a UDP port for the server from VOICE_PORTS and
  # assigns it as an extra allocation. Echoes the port, empty on failure.
  local uuid=$1 sid node_id ip lo hi port row
  sid=$(mysql -N -B -e "SELECT id FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null)
  case "$sid" in ''|*[!0-9]*) return 1 ;; esac
  read -r lo hi <<EOF
$(perf_voice_port_range)
EOF
  port=$(mysql -N -B -e "SELECT port FROM pelican.allocations WHERE server_id=$sid AND port BETWEEN $lo AND $hi ORDER BY port LIMIT 1;" 2>/dev/null)
  if [ -n "$port" ]; then
    echo "$port"
    return 0
  fi
  node_id=$(mysql -N -B -e "SELECT node_id FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null)
  case "$node_id" in ''|*[!0-9]*) return 1 ;; esac
  ip=$(mysql -N -B -e "SELECT ip FROM pelican.allocations WHERE node_id=$node_id LIMIT 1;" 2>/dev/null)
  ip=${ip:-0.0.0.0}
  port=$lo
  while [ "$port" -le "$hi" ]; do
    row=$(mysql -N -B -e "SELECT COALESCE(server_id,0) FROM pelican.allocations WHERE node_id=$node_id AND ip='$ip' AND port=$port LIMIT 1;" 2>/dev/null)
    if [ -z "$row" ]; then
      if mysql -e "INSERT INTO pelican.allocations (node_id, ip, port, server_id, show_port, is_locked, created_at, updated_at) VALUES ($node_id, '$ip', $port, $sid, 1, 0, NOW(), NOW());" 2>>"$INSTALL_LOG"; then
        echo "$port"
        return 0
      fi
    elif [ "$row" = "0" ]; then
      if mysql -e "UPDATE pelican.allocations SET server_id=$sid, updated_at=NOW() WHERE node_id=$node_id AND ip='$ip' AND port=$port;" 2>>"$INSTALL_LOG"; then
        echo "$port"
        return 0
      fi
    elif [ "$row" = "$sid" ]; then
      echo "$port"
      return 0
    fi
    port=$(( port + 1 ))
  done
  return 1
}

perf_props_set_port() {
  # Merge/replace the `port=` key of a properties file (creates it with the
  # documented minimal keys when missing).
  local file=$1 port=$2 tmp
  tmp=$(mktemp) || return 1
  if [ -f "$file" ]; then
    awk -v p="$port" '
      /^[[:space:]]*port[[:space:]]*=/ { print "port=" p; found=1; next }
      { print }
      END { if (!found) print "port=" p }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    {
      echo "# Managed by the Pelican installer (Simple Voice Chat quick setup)."
      echo "# Clients need the matching Simple Voice Chat client mod."
      echo "port=$port"
      echo "bind_address="
    } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

perf_voice_loader_map() {
  # profile + raw haystack -> "modrinth-loader|mod|plugin"
  local profile=$1 hay=$2
  case "$hay" in
    *quilt*) echo "quilt|mod"; return 0 ;;
  esac
  case "$profile" in
    mc-fabric) echo "fabric|mod" ;;
    mc-forge) echo "forge|mod" ;;
    mc-neoforge) echo "neoforge|mod" ;;
    mc-paper) echo "paper|plugin" ;;
    *) echo "" ;;
  esac
}

perf_voice_modrinth_pick() {
  # loader + mc version -> "filename|url|version_number" (prefers releases)
  local loader=$1 mc=$2 resp
  resp=$(curl -fsSL -m 25 -H "User-Agent: $PERF_VOICECHAT_UA" --get \
    --data-urlencode "loaders=[\"$loader\"]" \
    --data-urlencode "game_versions=[\"$mc\"]" \
    "https://api.modrinth.com/v2/project/$PERF_VOICECHAT_PROJECT/version" 2>/dev/null) || return 1
  printf '%s' "$resp" | jq -r '
    ([.[] | select(.version_type == "release")][0] // .[0]) as $v
    | if $v then "\($v.files[0].filename)|\($v.files[0].url)|\($v.version_number)" else empty end
  ' 2>/dev/null
}

perf_resolve_mc_latest() {
  if command -v resolve_mc_latest >/dev/null 2>&1; then
    resolve_mc_latest
    return 0
  fi
  curl -fsSL -m 30 "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json" 2>/dev/null \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["latest"]["release"])' 2>/dev/null || true
}

perf_voicechat_find_existing() {
  # args: volume dir [prefer mod|plugin]
  # echoes "kind|path" when a voice chat jar is already present (modpacks
  # often bundle it - in that case setup must not download a second copy).
  local dir=$1 prefer=${2:-mod} f
  if [ "$prefer" = "plugin" ]; then
    f=$(find "$dir/plugins" -maxdepth 1 -iname 'voicechat*.jar' 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "plugin|$f"; return 0; }
    f=$(find "$dir/mods" -maxdepth 1 -iname 'voicechat*.jar' 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "mod|$f"; return 0; }
  else
    f=$(find "$dir/mods" -maxdepth 1 -iname 'voicechat*.jar' 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "mod|$f"; return 0; }
    f=$(find "$dir/plugins" -maxdepth 1 -iname 'voicechat*.jar' 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "plugin|$f"; return 0; }
  fi
  return 1
}

perf_voicechat_setup() {
  local uuid=$1
  local dir="$PERF_VOLUMES/$uuid"
  if [ ! -d "$dir" ]; then
    perf_write_result "$uuid" '{"ok": false, "error": "server volume not found"}'
    return 0
  fi

  local egg_name images startup profile hay map loader kind mc
  egg_name=$(mysql -N -B -e "SELECT COALESCE(e.name,'') FROM pelican.servers s LEFT JOIN pelican.eggs e ON e.id=s.egg_id WHERE s.uuid='$uuid';" 2>/dev/null)
  images=$(mysql -N -B -e "SELECT COALESCE(e.docker_images,'') FROM pelican.servers s LEFT JOIN pelican.eggs e ON e.id=s.egg_id WHERE s.uuid='$uuid';" 2>/dev/null)
  startup=$(perf_server_field "$uuid" startup)
  hay=$(printf '%s\n%s\n%s' "$egg_name" "$images" "$startup" | tr '[:upper:]' '[:lower:]')
  profile=$(perf_detect_profile "$egg_name" "$images" "$startup")
  map=$(perf_voice_loader_map "$profile" "$hay")
  loader=${map%%|*}
  kind=${map#*|}

  # Bundled by the modpack? Then this is a setup-only run: allocate the port,
  # write the config and open the firewall - never add a second copy.
  local existing ex_kind ex_file fname url ver rest target source
  local prefer=mod
  [ "$kind" = "plugin" ] && prefer=plugin
  existing=$(perf_voicechat_find_existing "$dir" "$prefer" || true)
  if [ -n "$existing" ]; then
    kind=${existing%%|*}
    target=${existing#*|}
    fname=$(basename "$target")
    ver="existing"
    source="existing"
  else
    if [ -z "$map" ] || [ -z "$loader" ] || [ "$loader" = "$map" ]; then
      perf_write_result "$uuid" "$(jq -nc --arg p "$profile" '{ok: false, action: "voicechat_setup", error: ("Simple Voice Chat quick setup supports Fabric, Forge, NeoForge, Quilt and Paper/Purpur servers - detected: " + $p)}')"
      return 0
    fi

    mc=$(perf_server_field "$uuid" MC_VERSION)
    case "$mc" in
      latest|LATEST|"") mc=$(perf_resolve_mc_latest) ;;
    esac
    if [ -z "$mc" ]; then
      perf_write_result "$uuid" '{"ok": false, "action": "voicechat_setup", "error": "could not determine the Minecraft version"}'
      return 0
    fi

    local picked
    picked=$(perf_voice_modrinth_pick "$loader" "$mc") || picked=""
    if [ -z "$picked" ]; then
      perf_write_result "$uuid" "$(jq -nc --arg l "$loader" --arg m "$mc" '{ok: false, action: "voicechat_setup", error: ("no Simple Voice Chat build for " + $l + " / " + $m + " on Modrinth")}')"
      return 0
    fi
    fname=${picked%%|*}
    rest=${picked#*|}
    url=${rest%%|*}
    ver=${rest#*|}
    source="modrinth"

    case "$kind" in
      plugin) target="$dir/plugins/$fname" ;;
      *) target="$dir/mods/$fname" ;;
    esac
  fi

  if [ "$source" = "modrinth" ] && [ ! -f "$target" ]; then
    mkdir -p "$(dirname "$target")"
    if ! run_with_heartbeat "voice chat download ($loader $mc)" 300 \
         curl -fsSL -m 240 -o "$target.tmp" "$url" \
       || [ "$(stat -c %s "$target.tmp" 2>/dev/null || echo 0)" -lt 50000 ]; then
      rm -f "$target.tmp"
      perf_write_result "$uuid" '{"ok": false, "action": "voicechat_setup", "error": "voice chat download failed or was truncated"}'
      return 0
    fi
    mv -f "$target.tmp" "$target"
  fi
  chown pelican:pelican "$target" 2>/dev/null || true

  local port
  port=$(perf_voice_port_allocate "$uuid" || true)
  if [ -z "$port" ]; then
    perf_write_result "$uuid" "$(jq -nc --arg r "$VOICE_PORTS" '{ok: false, action: "voicechat_setup", error: ("no free UDP port in VOICE_PORTS (" + $r + ")")}')"
    return 0
  fi

  local cfg
  case "$kind" in
    plugin) cfg="$dir/plugins/voicechat/voicechat-server.properties" ;;
    *) cfg="$dir/config/voicechat/voicechat-server.properties" ;;
  esac
  mkdir -p "$(dirname "$cfg")"
  if ! perf_props_set_port "$cfg" "$port"; then
    perf_write_result "$uuid" '{"ok": false, "action": "voicechat_setup", "error": "could not write voicechat-server.properties"}'
    return 0
  fi
  chown -R pelican:pelican "$(dirname "$cfg")" 2>/dev/null || true
  # Modpacks ship default configs that get copied over config/ on server start -
  # keep the port there too or the allocation stops matching after a restart.
  local pack_cfg="$dir/defaultconfigs/voicechat/voicechat-server.properties"
  if [ -f "$pack_cfg" ]; then
    perf_props_set_port "$pack_cfg" "$port" || true
    chown pelican:pelican "$pack_cfg" 2>/dev/null || true
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status 2>/dev/null | grep -qE "(^|[^0-9])${port}/udp"; then
      ufw allow "$port/udp" >/dev/null 2>&1 || true
    fi
  fi

  mkdir -p "$dir/.perf"
  jq -nc --arg f "$target" --argjson p "$port" --arg v "$ver" --arg l "$loader" --arg m "${mc:-}" \
    '{file:$f, port:$p, version:$v, loader:$l, mc:$m}' > "$dir/.perf/voicechat.json" 2>/dev/null || true
  chown -R pelican:pelican "$dir/.perf" 2>/dev/null || true

  local note
  if [ "$source" = "existing" ]; then
    note="Simple Voice Chat is already bundled ($fname) - no download needed. Allocated UDP $port, wrote the server config and opened the firewall. Restart the server to apply. Every player needs the matching client mod."
  else
    note="Installed $fname from Modrinth. Restart the server to load it. Every player needs the Simple Voice Chat client mod (modrinth.com/plugin/simple-voice-chat). Direct players connect over UDP $port. Through playit: add a custom UDP tunnel (premium) for port $port and set voice_host in voicechat-server.properties if the public port differs."
  fi
  perf_write_result "$uuid" "$(jq -nc --arg f "$fname" --argjson p "$port" --arg v "$ver" --arg k "$kind" --arg s "$source" --arg n "$note" \
    '{ok: true, action: "voicechat_setup", file: $f, port: $p, version: $v, kind: $k, source: $s, note: $n}')"
  return 0
}

perf_voicechat_disable() {
  local uuid=$1
  local dir="$PERF_VOLUMES/$uuid" manifest="$PERF_VOLUMES/$uuid/.perf/voicechat.json"
  local file
  file=$(jq -r '.file // empty' "$manifest" 2>/dev/null || true)
  rm -f "$manifest" 2>/dev/null || true
  if [ -n "$file" ] && [ -f "$file" ]; then
    rm -f "$file"
    perf_write_result "$uuid" '{"ok": true, "action": "voicechat_disable", "note": "Voice chat mod removed. The extra UDP allocation and firewall rule stay (harmless) - remove them in the panel if you want."}'
  else
    perf_write_result "$uuid" '{"ok": true, "action": "voicechat_disable", "note": "Nothing to remove - the mod was not added by this plugin."}'
  fi
  return 0
}

perf_apply_request() {
  local uuid=$1 raw op profile
  case "$uuid" in
    *[!0-9a-fA-F-]*|"") return 0 ;;
  esac
  raw=$(cat "$PERF_REQUEST_DIR/perf-$uuid.req" 2>/dev/null || echo "")
  rm -f "$PERF_REQUEST_DIR/perf-$uuid.req"

  op=$(printf '%s' "$raw" | jq -r '.op // empty' 2>/dev/null || true)
  if [ -n "$op" ]; then
    profile=$(printf '%s' "$raw" | jq -r '.profile // empty' 2>/dev/null || true)
  else
    case "$raw" in
      revert) op="revert" ;;
      *) op="apply"; profile="$raw" ;;
    esac
  fi

  local exists
  exists=$(mysql -N -B -e "SELECT uuid FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null)
  if [ -z "$exists" ]; then
    perf_write_result "$uuid" '{"ok": false, "error": "server not found"}'
    return 0
  fi

  case "$op" in
    boot_cache)
      perf_boot_request "$uuid" "$raw"
      return 0
      ;;
    voicechat_setup)
      perf_voicechat_setup "$uuid"
      return 0
      ;;
    voicechat_disable)
      perf_voicechat_disable "$uuid"
      return 0
      ;;
    mods_apply|mods_revert)
      if command -v modopt_request >/dev/null 2>&1; then
        modopt_request "$uuid" "$op"
      else
        perf_write_result "$uuid" '{"ok": false, "error": "optimizer mods support is not installed on this host"}'
      fi
      return 0
      ;;
  esac

  if [ "$op" = "revert" ]; then
    local original memory_old files
    original=$(jq -r --arg u "$uuid" '.[$u].original_startup // empty' "$PERF_APPLIED_FILE" 2>/dev/null)
    if [ -z "$original" ]; then
      perf_write_result "$uuid" '{"ok": false, "error": "no applied tuning to revert"}'
      return 0
    fi
    memory_old=$(jq -r --arg u "$uuid" '.[$u].memory_old // 0' "$PERF_APPLIED_FILE" 2>/dev/null)
    case "$memory_old" in ''|null|*[!0-9]*) memory_old=0 ;; esac
    files=$(jq -c --arg u "$uuid" '.[$u].files // []' "$PERF_APPLIED_FILE" 2>/dev/null)
    perf_restore_files "$uuid" "$files"
    mysql -e "UPDATE pelican.servers SET startup='$(perf_sql_escape "$original")', memory=$memory_old WHERE uuid='$uuid';" 2>>"$INSTALL_LOG"
    jq --arg u "$uuid" 'del(.[$u])' "$PERF_APPLIED_FILE" > "$PERF_APPLIED_FILE.tmp" 2>/dev/null \
      && mv -f "$PERF_APPLIED_FILE.tmp" "$PERF_APPLIED_FILE"
    perf_mirror_applied
    log "Server $uuid: tuning reverted (startup, memory and config files)."
    perf_write_result "$uuid" '{"ok": true, "action": "reverted"}'
    perf_scan
    return 0
  fi

  local profile_now chosen upd heap rec recmem mem cur
  profile_now=$(jq -r --arg u "$uuid" '.servers[$u].profile // "generic"' "$PERF_REC_FILE" 2>/dev/null)
  chosen=${profile:-$profile_now}
  mem=$(mysql -N -B -e "SELECT COALESCE(memory,0) FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null); mem=${mem:-0}
  case "$mem" in ''|*[!0-9]*) mem=0 ;; esac
  cur=$(mysql -N -B -e "SELECT COALESCE(startup,'') FROM pelican.servers WHERE uuid='$uuid';" 2>/dev/null)

  upd=$(perf_update_startup_db "$uuid" "$chosen")
  heap=$(printf '%s' "$upd" | jq -r '.heap_mb')
  rec=$(printf '%s' "$upd" | jq -r '.startup // empty')
  recmem=$(printf '%s' "$upd" | jq -r '.memory_mb')

  local props files_applied
  props=$(perf_recommend_server_props "$chosen" "$PERF_VOLUMES/$uuid" "$(perf_ram_avail_mb)" "0" "$(perf_core_count)" "$(perf_cant_keep_up "$uuid")")
  files_applied=$(perf_apply_files "$uuid" "$PERF_VOLUMES/$uuid" "$props" "$heap")
  if [ "$chosen" = "mc-pumpkin" ]; then
    local pumprecs pumpkin_applied
    pumprecs=$(perf_recommend_pumpkin_toml "$PERF_VOLUMES/$uuid" "$(perf_ram_avail_mb)" "$(perf_cant_keep_up "$uuid")" "")
    pumpkin_applied=$(perf_apply_pumpkin_toml "$uuid" "$PERF_VOLUMES/$uuid" "$pumprecs")
    files_applied=$(jq -nc --argjson a "$files_applied" --argjson b "$pumpkin_applied" '$a + $b' 2>/dev/null) \
      || files_applied="$files_applied"
  fi

  jq --arg u "$uuid" --arg p "$chosen" --arg o "$cur" --argjson m "$mem" --argjson f "$files_applied" \
    '.[$u] = {profile: $p, original_startup: $o, memory_old: $m, applied_at: (now | todate), files: $f}' \
    "$PERF_APPLIED_FILE" > "$PERF_APPLIED_FILE.tmp" 2>/dev/null \
    && mv -f "$PERF_APPLIED_FILE.tmp" "$PERF_APPLIED_FILE"

  perf_mirror_applied

  log "Server $uuid: applied '$chosen' tuning - startup, memory=${recmem}MB and config files (restart the server to take effect)."
  local result_json
  result_json=$(jq -nc --arg s "$rec" --argjson m "$recmem" --argjson f "$files_applied" \
    '{ok: true, action: "applied", startup: $s, memory_mb: $m, files: $f}' 2>/dev/null) \
    || result_json='{"ok": false, "error": "internal error"}'
  perf_write_result "$uuid" "$result_json"
  perf_scan
  return 0
}

perfctl_process_requests() {
  [ -d "$PERF_REQUEST_DIR" ] || mkdir -p "$PERF_REQUEST_DIR" 2>/dev/null
  [ -d "$PERF_REQUEST_DIR" ] || return 0
  chown www-data:www-data "$PERF_REQUEST_DIR" 2>/dev/null || true
  local req uuid
  for req in "$PERF_REQUEST_DIR"/perf-*.req; do
    [ -e "$req" ] || continue
    uuid=$(basename "$req" .req | sed 's/^perf-//')
    case "$uuid" in
      *[!0-9a-fA-F-]*|"")
        log_err "Ignoring invalid perf request: $(basename "$req")"
        rm -f "$req"
        continue
        ;;
    esac
    perf_apply_request "$uuid"
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
