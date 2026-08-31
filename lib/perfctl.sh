PERF_REC_FILE="$PANEL_STORAGE/perf-recommendations.json"
PERF_APPLIED_FILE="$PI_ROOT/perf-applied.json"
PERF_REQUEST_DIR="$PANEL_STORAGE/requests"
PERF_VOLUMES="${PERF_VOLUMES:-/var/lib/pelican/volumes}"
PERF_BACKUP_DIR="${PERF_BACKUP_DIR:-$PANEL_STORAGE/perf-backups}"
PERF_INFRA_RESERVE_LOW_MB="${PERF_INFRA_RESERVE_LOW_MB:-2048}"
PERF_INFRA_RESERVE_HIGH_MB="${PERF_INFRA_RESERVE_HIGH_MB:-3072}"

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

perf_recommend_startup() {
  local profile=$1 heap=$2 startup=$3
  local cleaned flags
  case "$profile" in
    mc-paper|mc-fabric|mc-forge|mc-generic)
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
      printf '%s --max-old-space-size=%s' "${startup% }" "$heap"
      ;;
    *)
      printf '%s' "$startup"
      ;;
  esac
}

perf_profile_heap_floor_mb() {
  case "$1" in
    mc-forge|mc-fabric) echo 4096 ;;
    mc-paper) echo 2560 ;;
    mc-generic) echo 1024 ;;
    proxy-java) echo 1024 ;;
    *) echo 512 ;;
  esac
}

perf_profile_overhead_mb() {
  case "$1" in
    mc-forge|mc-fabric) echo 1792 ;;
    mc-paper) echo 1280 ;;
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
    mc-*|generic)
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
    mc-*) ;;
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
  local query="SELECT s.uuid, COALESCE(s.name,''), COALESCE(s.startup,''), COALESCE(s.memory,0), COALESCE(e.name,''), COALESCE(e.docker_images,'') FROM pelican.servers s LEFT JOIN pelican.eggs e ON s.egg_id = e.id WHERE s.uuid IS NOT NULL;"
  mysql -N -B -e "$query" 2>/dev/null > "$rows" || true

  local rss_sum=0 uuid_r
  while IFS=$'\t' read -r uuid_r _ _ _ _ _; do
    [ -n "$uuid_r" ] || continue
    rss_sum=$(( rss_sum + $(perf_docker_rss_mb "$uuid_r") ))
  done < "$rows"

  local budget_json infra_reserve budget
  budget_json=$(perf_node_budget "$total_ram" "$avail_ram" "$rss_sum")
  infra_reserve=$(printf '%s' "$budget_json" | jq -r '.reserve_mb')
  budget=$(printf '%s' "$budget_json" | jq -r '.budget_mb')

  local sum_allocated=0 sum_recommended=0 server_count=0

  while IFS=$'\t' read -r uuid name startup memory egg_name images; do
    [ -n "$uuid" ] || continue
    memory=${memory:-0}
    case "$memory" in ''|*[!0-9]*) memory=0 ;; esac
    local profile rec reason ooms mem_json heap recmem unb mnote
    local eff rss restarts keepup props jvms yamlc slow
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
    rec=$(perf_recommend_startup "$profile" "$heap" "$startup")
    ooms=$(perf_recent_ooms "$uuid")
    reason=$(perf_reason_text "$profile" "$ooms")
    props=$(perf_recommend_server_props "$profile" "$PERF_VOLUMES/$uuid" "$avail_ram" "$load1" "$cores" "$keepup")
    jvms=$(perf_recommend_jvm_args "$profile" "$PERF_VOLUMES/$uuid" "$heap")
    yamlc=$(perf_detect_yaml_configs "$PERF_VOLUMES/$uuid")
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
      --argjson pr "$props" --argjson jv "$jvms" --argjson ym "$yamlc" \
      --argjson ping "${ping_ms:-null}" --argjson slow "$slow" \
      '{uuid:$id, name:$n, profile:$p, current_startup:$cur,
        recommended_startup:$rec, reason:$r, memory_mb:$m, recent_ooms:$o,
        effective_limit_mb:$eff, rss_mb:$rss,
        recommended_memory_mb:$recmem, recommended_heap_mb:$heap,
        unbounded:$unb, mem_note:$mn,
        restart_count:$rst, cant_keep_up_count:$kpu,
        file_recs:{"server.properties":$pr, user_jvm_args:$jv, yaml_configs:$ym},
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
  return 0
}

perf_apply_request() {
  local uuid=$1 raw op profile
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
    echo '{"ok": false, "error": "server not found"}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
    return 0
  fi

  if [ "$op" = "revert" ]; then
    local original memory_old files
    original=$(jq -r --arg u "$uuid" '.[$u].original_startup // empty' "$PERF_APPLIED_FILE" 2>/dev/null)
    if [ -z "$original" ]; then
      echo '{"ok": false, "error": "no applied tuning to revert"}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
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
    echo '{"ok": true, "action": "reverted"}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
    perf_scan
    return 0
  fi

  local total_ram avail_ram budget eff mem cur rss_sum
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

  local profile_now chosen mem_json heap rec recmem
  profile_now=$(jq -r --arg u "$uuid" '.servers[$u].profile // "generic"' "$PERF_REC_FILE" 2>/dev/null)
  chosen=${profile:-$profile_now}
  mem_json=$(perf_recommend_memory "$chosen" "$mem" "$eff" "$budget")
  heap=$(printf '%s' "$mem_json" | jq -r '.recommended_heap_mb')
  recmem=$(printf '%s' "$mem_json" | jq -r '.recommended_memory_mb')
  rec=$(perf_recommend_startup "$chosen" "$heap" "$cur")

  local props files_applied
  props=$(perf_recommend_server_props "$chosen" "$PERF_VOLUMES/$uuid" "$(perf_ram_avail_mb)" "0" "$(perf_core_count)" "$(perf_cant_keep_up "$uuid")")
  files_applied=$(perf_apply_files "$uuid" "$PERF_VOLUMES/$uuid" "$props" "$heap")

  jq --arg u "$uuid" --arg p "$chosen" --arg o "$cur" --argjson m "$mem" --argjson f "$files_applied" \
    '.[$u] = {profile: $p, original_startup: $o, memory_old: $m, applied_at: (now | todate), files: $f}' \
    "$PERF_APPLIED_FILE" > "$PERF_APPLIED_FILE.tmp" 2>/dev/null \
    && mv -f "$PERF_APPLIED_FILE.tmp" "$PERF_APPLIED_FILE"

  perf_mirror_applied

  mysql -e "UPDATE pelican.servers SET startup='$(perf_sql_escape "$rec")', memory=$recmem WHERE uuid='$uuid';" 2>>"$INSTALL_LOG"
  log "Server $uuid: applied '$chosen' tuning - startup, memory=${recmem}MB and config files (restart the server to take effect)."
  jq -nc --arg s "$rec" --argjson m "$recmem" --argjson f "$files_applied" \
    '{ok: true, action: "applied", startup: $s, memory_mb: $m, files: $f}' > "$PERF_REQUEST_DIR/perf-$uuid.result"
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
