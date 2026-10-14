MODOPT_MANIFEST="${MODOPT_MANIFEST:-$PI_ROOT/mod-optimizer.json}"
MODOPT_PLAN_FILE="${MODOPT_PLAN_FILE:-$PI_ROOT/modopt-plans.json}"
MODOPT_API="${MODOPT_API:-https://api.modrinth.com/v2}"

modopt_catalog() {
  cat <<'EOF'
modernfix|Cuts modpack boot time sharply and lowers base memory use
ferrite-core|Large RAM savings by deduplicating block-state and model data
lithium|Optimizes entity AI, physics and chunk ticking with no gameplay changes
canary|Lithium's tick optimizations for Forge - less CPU per tick
radium|Lithium-style tick optimizations for Forge/NeoForge
krypton|Optimizes the network stack and packet handling
c2me-fabric|Multithreaded chunk generation and loading
noisium|Faster, more memory-friendly world generation
structure-layout-optimizer|Speeds up structure generation
vmp-fabric|Better entity tracking and player scaling
EOF
}

modopt_ua() {
  printf 'pelicaninstaller-perfctl/%s (+https://github.com/erwinwermach/pelicaninstaller)' \
    "$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo dev)"
}

modopt_var() {
  mysql -N -B -e "SELECT sv.variable_value FROM pelican.egg_variables ev JOIN pelican.server_variables sv ON sv.variable_id=ev.id JOIN pelican.servers s ON s.id=sv.server_id WHERE s.uuid='$1' AND ev.env_variable='$2';" 2>/dev/null | head -1
}

modopt_mc_version() {
  local uuid=$1 dir=$2 loader=$3 v val
  for v in MC_VERSION MINECRAFT_VERSION SERVER_MC_VERSION MCVERSION; do
    val=$(modopt_var "$uuid" "$v")
    case "$val" in ''|latest|LATEST) ;; *) printf '%s' "$val"; return ;; esac
  done
  if [ -d "$dir/libraries/net/fabricmc/intermediary" ]; then
    v=$(ls "$dir/libraries/net/fabricmc/intermediary" 2>/dev/null | sort -V | tail -1)
    case "$v" in ''|*[!0-9a-zA-Z._+-]*) ;; *) printf '%s' "$v"; return ;; esac
  fi
  case "$loader" in
    forge)
      v=$(find "$dir/libraries/net/minecraftforge/forge" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)
      case "$v" in *-*) printf '%s' "${v%%-*}"; return ;; esac
      ;;
    neoforge)
      v=$(find "$dir/libraries/net/neoforged/neoforge" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)
      case "$v" in *-*) v=${v%%-*} ;; esac
      case "$v" in
        ''|*[!0-9.]*) ;;
        *)
          local maj=${v%%.*} min=${v#*.}
          min=${min%%.*}
          if [ "$min" = "0" ]; then printf '1.%s' "$maj"; else printf '1.%s.%s' "$maj" "$min"; fi
          return
          ;;
      esac
      ;;
  esac
  echo ""
}

modopt_detect() {
  # echoes "loader|mc_version" (empty loader = not a modded Java server we can handle)
  local uuid=$1
  local dir="$PERF_VOLUMES/$uuid" loader="" det
  [ -d "$dir/mods" ] || { echo "|"; return; }
  if [ -d "$dir/libraries/net/neoforged" ]; then
    loader=neoforge
  elif [ -d "$dir/libraries/net/minecraftforge" ]; then
    loader=forge
  elif [ -d "$dir/libraries/org/quiltmc" ] || [ -f "$dir/quilt-server-launch.jar" ]; then
    loader=quilt
  elif [ -d "$dir/libraries/net/fabricmc" ] || [ -f "$dir/fabric-server-launch.jar" ] || [ -f "$dir/fabric-server-launcher.jar" ]; then
    loader=fabric
  fi
  if [ -z "$loader" ]; then
    det=$(modopt_var "$uuid" "LOADER_TYPE")
    case "$(printf '%s' "$det" | tr '[:upper:]' '[:lower:]')" in
      *neoforge*) loader=neoforge ;;
      *forge*) loader=forge ;;
      *quilt*) loader=quilt ;;
      *fabric*) loader=fabric ;;
    esac
  fi
  [ -n "$loader" ] || { echo "|"; return; }
  printf '%s|%s' "$loader" "$(modopt_mc_version "$uuid" "$dir" "$loader")"
}

modopt_resolve() {
  # args: loader mc_version -> JSON array of {slug,title,version,filename,url,sha1,reason}
  local loader=$1 mc=$2
  [ -n "$loader" ] && [ -n "$mc" ] || { echo "[]"; return; }
  local try_loaders="$loader" ua out="[]" slug reason resp entry L ids titles
  [ "$loader" = "quilt" ] && try_loaders="quilt fabric"
  ua=$(modopt_ua)
  while IFS='|' read -r slug reason; do
    [ -n "$slug" ] || continue
    entry=""
    for L in $try_loaders; do
      resp=$(curl -fsSL -m 25 -H "User-Agent: $ua" \
        "$MODOPT_API/project/$slug/version?loaders=%5B%22$L%22%5D&game_versions=%5B%22$mc%22%5D" 2>/dev/null) || resp=""
      [ -n "$resp" ] || continue
      entry=$(printf '%s' "$resp" | jq -c '
        (map(select(.version_type == "release")) | first) // .[0] // empty
        | {project_id: .project_id, version: .version_number,
           file: ((.files | map(select(.primary == true)) | first) // .files[0])}
        | {project_id, version, url: .file.url, filename: .file.filename, sha1: (.file.hashes.sha1 // "")}
      ' 2>/dev/null) || entry=""
      case "$entry" in ''|null) entry="" ;; *) break ;; esac
    done
    if [ -n "$entry" ]; then
      out=$(jq -c --argjson e "$entry" --arg s "$slug" --arg r "$reason" \
        '. + [($e + {slug:$s, reason:$r})]' <<<"$out" 2>/dev/null) || out="$out"
    fi
  done <<EOF
$(modopt_catalog)
EOF
  ids=$(jq -c '[.[].project_id] | unique' <<<"$out" 2>/dev/null)
  if [ -n "$ids" ] && [ "$ids" != "[]" ] && [ "$ids" != "null" ]; then
    titles=$(curl -fsSL -m 25 -H "User-Agent: $ua" -G --data-urlencode "ids=$ids" "$MODOPT_API/projects" 2>/dev/null) || titles=""
    case "$titles" in
      \[*) out=$(jq -c --argjson t "$titles" \
             'map(. + {title: (($t[]? | select(.id == .project_id) | .title) // .slug)})' <<<"$out" 2>/dev/null) || out="$out" ;;
    esac
  fi
  jq -c 'map(. + {title: (.title // .slug)})' <<<"$out" 2>/dev/null || echo "$out"
}

modopt_plan() {
  # args: uuid [force] -> JSON plan (cached 3 days unless force=yes)
  local uuid=$1 force=${2:-no}
  if [ "${OPTIMIZER_MODS:-yes}" = "no" ]; then
    echo '{"eligible":false,"reason":"optimizer mods disabled in installer.conf"}'
    return
  fi
  local det loader mc
  det=$(modopt_detect "$uuid")
  loader=${det%%|*}
  mc=${det##*|}
  if [ -z "$loader" ] || [ -z "$mc" ]; then
    echo '{"eligible":false,"reason":"Not a modded Java Minecraft server (or loader/Minecraft version could not be detected)."}'
    return
  fi
  [ -f "$MODOPT_PLAN_FILE" ] || echo '{}' > "$MODOPT_PLAN_FILE"
  chmod 600 "$MODOPT_PLAN_FILE" 2>/dev/null || true
  local now cached_at stored_loader stored_mc
  now=$(date +%s)
  cached_at=$(jq -r --arg u "$uuid" '.[$u].cached_at // 0' "$MODOPT_PLAN_FILE" 2>/dev/null)
  case "$cached_at" in ''|*[!0-9]*) cached_at=0 ;; esac
  stored_loader=$(jq -r --arg u "$uuid" '.[$u].loader // ""' "$MODOPT_PLAN_FILE" 2>/dev/null)
  stored_mc=$(jq -r --arg u "$uuid" '.[$u].mc_version // ""' "$MODOPT_PLAN_FILE" 2>/dev/null)
  if [ "$force" != "yes" ] && [ "$cached_at" -gt 0 ] && [ "$stored_loader" = "$loader" ] && [ "$stored_mc" = "$mc" ] \
     && [ $(( now - cached_at )) -lt 259200 ]; then
    jq -c --arg u "$uuid" '.[$u]' "$MODOPT_PLAN_FILE" 2>/dev/null
    return
  fi
  local proposed plan
  proposed=$(modopt_resolve "$loader" "$mc")
  plan=$(jq -nc --arg l "$loader" --arg m "$mc" --argjson p "$proposed" --argjson t "$now" \
    '{eligible:true, loader:$l, mc_version:$m, proposed:$p, cached_at:$t}')
  if jq --arg u "$uuid" --argjson v "$plan" '.[$u] = $v' "$MODOPT_PLAN_FILE" > "$MODOPT_PLAN_FILE.tmp" 2>/dev/null; then
    mv -f "$MODOPT_PLAN_FILE.tmp" "$MODOPT_PLAN_FILE" 2>/dev/null || rm -f "$MODOPT_PLAN_FILE.tmp"
  else
    rm -f "$MODOPT_PLAN_FILE.tmp" 2>/dev/null
  fi
  printf '%s' "$plan"
}

modopt_slug_present() {
  local dir=$1 slug=$2 norm f base
  norm=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | tr -d -- '-_')
  for f in "$dir/mods"/*.jar "$dir/mods"/*.jar.disabled; do
    [ -e "$f" ] || continue
    base=$(basename "$f" | tr '[:upper:]' '[:lower:]' | tr -d -- '-_')
    case "$base" in *"$norm"*) return 0 ;; esac
  done
  case "$slug" in
    structure-layout-optimizer) ls "$dir/mods"/*slo* >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

modopt_scan() {
  # args: uuid profile -> JSON blob for perf-recommendations.json
  local uuid=$1 profile=$2
  if [ "${OPTIMIZER_MODS:-yes}" = "no" ]; then
    echo '{}'
    return 0
  fi
  case "$profile" in
    mc-fabric|mc-forge|mc-neoforge) ;;
    *) echo '{}'; return 0 ;;
  esac
  local dir="$PERF_VOLUMES/$uuid" plan
  plan=$(modopt_plan "$uuid")
  case "$plan" in
    \{*) ;;
    *) echo '{}'; return 0 ;;
  esac
  if [ "$(printf '%s' "$plan" | jq -r '.eligible // false' 2>/dev/null)" != "true" ]; then
    printf '%s' "$plan" | jq -c '{eligible:false, reason:(.reason // "not eligible")}' 2>/dev/null || echo '{}'
    return 0
  fi
  local out="[]" slug title version filename reason present
  while IFS=$'\t' read -r slug title version filename reason; do
    [ -n "$slug" ] || continue
    present=false
    if modopt_slug_present "$dir" "$slug"; then present=true; fi
    out=$(jq -c --arg s "$slug" --arg t "$title" --arg v "$version" --arg f "$filename" \
      --arg r "$reason" --argjson p "$present" \
      '. + [{slug:$s, title:$t, version:$v, filename:$f, reason:$r, already_present:$p}]' <<<"$out" 2>/dev/null) || out="$out"
  done < <(printf '%s' "$plan" | jq -r '.proposed[]? | [.slug, (.title // .slug), .version, .filename, .reason] | @tsv' 2>/dev/null)
  local missing applied
  missing=$(jq '[.[] | select(.already_present == false)] | length' <<<"$out" 2>/dev/null)
  case "$missing" in ''|*[!0-9]*) missing=0 ;; esac
  applied="[]"
  if [ -f "$MODOPT_MANIFEST" ]; then
    applied=$(jq -c --arg u "$uuid" '[.[$u].files[]? | .filename]' "$MODOPT_MANIFEST" 2>/dev/null) || applied="[]"
  fi
  jq -nc \
    --arg l "$(printf '%s' "$plan" | jq -r '.loader // ""')" \
    --arg v "$(printf '%s' "$plan" | jq -r '.mc_version // ""')" \
    --argjson p "$out" --argjson a "$applied" --argjson m "$missing" \
    '{eligible:true, loader:$l, mc_version:$v, proposed:$p, applied:$a, missing:$m,
      note:(if $m == 0
            then "All recommended server-side optimization mods are already installed."
            else "Server-side only - connecting players do not need these files. A restart activates them." end)}'
}

modopt_apply() {
  local uuid=$1
  local dir="$PERF_VOLUMES/$uuid" plan eligible why
  plan=$(modopt_plan "$uuid" yes)
  eligible=$(printf '%s' "$plan" | jq -r '.eligible // false' 2>/dev/null)
  if [ "$eligible" != "true" ]; then
    why=$(printf '%s' "$plan" | jq -r '.reason // "not eligible for optimizer mods"' 2>/dev/null)
    perf_write_result "$uuid" "$(jq -nc --arg e "$why" '{ok: false, error: $e}')"
    return 0
  fi
  if [ ! -d "$dir" ]; then
    perf_write_result "$uuid" '{"ok": false, "error": "server volume not found"}'
    return 0
  fi
  mkdir -p "$dir/mods" 2>/dev/null || true
  chown pelican:pelican "$dir/mods" 2>/dev/null || true

  local added="[]" skipped="[]" slug title version filename url sha1 reason tmp got
  while IFS=$'\t' read -r slug title version filename url sha1 reason; do
    [ -n "$slug" ] || continue
    case "$filename" in
      */*|"") skipped=$(jq -c --arg s "$slug" --arg w "unsafe filename" '. + [{slug:$s, reason:$w}]' <<<"$skipped"); continue ;;
    esac
    if modopt_slug_present "$dir" "$slug"; then
      skipped=$(jq -c --arg s "$slug" --arg w "already installed" '. + [{slug:$s, reason:$w}]' <<<"$skipped")
      continue
    fi
    tmp="$dir/mods/.modopt-$slug.tmp"
    if ! run_with_heartbeat "mod download ($slug)" 300 curl -fsSL -m 240 -o "$tmp" "$url"; then
      rm -f "$tmp" 2>/dev/null
      skipped=$(jq -c --arg s "$slug" --arg w "download failed" '. + [{slug:$s, reason:$w}]' <<<"$skipped")
      continue
    fi
    if [ -n "$sha1" ]; then
      got=$(sha1sum "$tmp" 2>/dev/null | cut -d' ' -f1)
      if [ "$got" != "$sha1" ]; then
        rm -f "$tmp" 2>/dev/null
        skipped=$(jq -c --arg s "$slug" --arg w "checksum mismatch" '. + [{slug:$s, reason:$w}]' <<<"$skipped")
        continue
      fi
    fi
    if ! mv -f "$tmp" "$dir/mods/$filename" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      skipped=$(jq -c --arg s "$slug" --arg w "could not write to mods folder" '. + [{slug:$s, reason:$w}]' <<<"$skipped")
      continue
    fi
    chown pelican:pelican "$dir/mods/$filename" 2>/dev/null || true
    added=$(jq -c --arg s "$slug" --arg t "$title" --arg v "$version" --arg f "$filename" --arg h "$sha1" --arg r "$reason" \
      '. + [{slug:$s, title:$t, version:$v, filename:$f, sha1:$h, reason:$r}]' <<<"$added" 2>/dev/null) || added="$added"
  done < <(printf '%s' "$plan" | jq -r '.proposed[]? | [.slug, (.title // .slug), .version, .filename, .url, (.sha1 // ""), .reason] | @tsv' 2>/dev/null)

  [ -f "$MODOPT_MANIFEST" ] || echo '{}' > "$MODOPT_MANIFEST"
  chmod 600 "$MODOPT_MANIFEST" 2>/dev/null || true
  local loader mc
  loader=$(printf '%s' "$plan" | jq -r '.loader // ""')
  mc=$(printf '%s' "$plan" | jq -r '.mc_version // ""')
  if jq --arg u "$uuid" --arg l "$loader" --arg m "$mc" --argjson a "$added" \
      '.[$u] = {loader:$l, mc_version:$m, applied_at:(now | todate),
                files: (((.[$u].files // []) | map(select(.slug as $s | ($a | map(.slug) | index($s)) | not))) + $a)}' \
      "$MODOPT_MANIFEST" > "$MODOPT_MANIFEST.tmp" 2>/dev/null; then
    mv -f "$MODOPT_MANIFEST.tmp" "$MODOPT_MANIFEST" 2>/dev/null || rm -f "$MODOPT_MANIFEST.tmp"
  else
    rm -f "$MODOPT_MANIFEST.tmp" 2>/dev/null
  fi

  local n
  n=$(printf '%s' "$added" | jq 'length' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  perf_write_result "$uuid" "$(jq -nc --argjson a "$added" --argjson s "$skipped" --argjson n "$n" \
    '{ok: true, action: "mods_applied", files: ($a | map(.filename)), skipped: $s, count: $n, restart_required: ($n > 0)}')"
  log "Server $uuid: optimizer mods applied (${n} added, $(printf '%s' "$skipped" | jq 'length') skipped)."
  perf_scan
  return 0
}

modopt_revert() {
  local uuid=$1
  local dir="$PERF_VOLUMES/$uuid" files removed="[]" f
  files="[]"
  if [ -f "$MODOPT_MANIFEST" ]; then
    files=$(jq -c --arg u "$uuid" '.[$u].files // []' "$MODOPT_MANIFEST" 2>/dev/null) || files="[]"
  fi
  if [ "$files" = "[]" ]; then
    perf_write_result "$uuid" '{"ok": false, "error": "no optimizer mods recorded for this server"}'
    return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in */*|"") continue ;; esac
    if [ -f "$dir/mods/$f" ]; then
      rm -f "$dir/mods/$f" 2>/dev/null \
        && removed=$(jq -c --arg f "$f" '. + [$f]' <<<"$removed" 2>/dev/null) || true
    fi
  done < <(printf '%s' "$files" | jq -r '.[].filename' 2>/dev/null)
  if jq --arg u "$uuid" 'del(.[$u])' "$MODOPT_MANIFEST" > "$MODOPT_MANIFEST.tmp" 2>/dev/null; then
    mv -f "$MODOPT_MANIFEST.tmp" "$MODOPT_MANIFEST" 2>/dev/null || rm -f "$MODOPT_MANIFEST.tmp"
  else
    rm -f "$MODOPT_MANIFEST.tmp" 2>/dev/null
  fi
  perf_write_result "$uuid" "$(jq -nc --argjson r "$removed" \
    '{ok: true, action: "mods_reverted", files: $r, restart_required: true}')"
  log "Server $uuid: optimizer mods reverted ($(printf '%s' "$removed" | jq 'length') removed)."
  perf_scan
  return 0
}

modopt_request() {
  local uuid=$1 op=$2
  case "$op" in
    mods_apply) modopt_apply "$uuid" ;;
    mods_revert) modopt_revert "$uuid" ;;
    *) perf_write_result "$uuid" '{"ok": false, "error": "unknown mods op"}' ;;
  esac
  return 0
}
