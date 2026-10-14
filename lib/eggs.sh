EXTRA_EGGS=${EXTRA_EGGS:-games,bots,minecraft}

egg_catalog() {
  # URLs verified against the pelican-eggs repos; several eggs moved upstream
  # in 2026 (counter-strike-2, tf2, gmod, palworld, terraria, factorio, fivem,
  # the generic runtimes and the chatbots) and used to import nothing.
  cat <<'EOF'
# steamcmd games (UDP-heavy where noted)
rust|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/rust/vanilla/egg-rust.yaml|udp
valheim|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/valheim/valheim_vanilla/egg-valheim.json|udp
7-days-to-die|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/7_days_to_die/egg-7-days-to-die.json|udp
counter-strike-2|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/counter_strike/counter_strike_2/egg-counter--strike2.yaml|udp
counter-strike-source|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/counter_strike/counter_strike_source/egg-counter--strike--source.yaml|udp
team-fortress-2|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/team_fortress_2/egg-team-fortress2.yaml|udp
garrys-mod|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/gmod/egg-garrys-mod.yaml|udp
palworld|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/palworld/egg-palworld.yaml|udp
satisfactory|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/satisfactory/egg-satisfactory.json|tcp
# standalone games
terraria|https://raw.githubusercontent.com/pelican-eggs/games-standalone/refs/heads/main/terraria/vanilla/egg-terraria-vanilla.json|tcp
factorio|https://raw.githubusercontent.com/pelican-eggs/games-standalone/refs/heads/main/factorio/factorio/egg-factorio.yaml|tcp
fivem|https://raw.githubusercontent.com/pelican-eggs/games-standalone/refs/heads/main/gta/fivem/egg-five-m.json|tcp
# generic runtimes (bots, apps, scripts)
python|https://raw.githubusercontent.com/pelican-eggs/generic/refs/heads/main/python/egg-python-generic.yaml|tcp
nodejs|https://raw.githubusercontent.com/pelican-eggs/generic/refs/heads/main/nodejs/egg-nodejs-generic.yaml|tcp
rust-lang|https://raw.githubusercontent.com/pelican-eggs/generic/refs/heads/main/rust/egg-rust-generic.yaml|tcp
# discord bots
discord-red|https://raw.githubusercontent.com/pelican-eggs/chatbots/refs/heads/main/discord/redbot/egg-red.yaml|tcp
discord-ree6|https://raw.githubusercontent.com/pelican-eggs/chatbots/refs/heads/main/discord/ree6/egg-ree6.yaml|tcp
# minecraft platforms (server software matrix incl. Rust-based Pumpkin)
paper|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/paper/egg-paper.yaml|tcp
purpur|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/purpur/egg-purpur.yaml|tcp
folia|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/folia/egg-folia.yaml|tcp
vanilla|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/vanilla/egg-vanilla-minecraft.yaml|tcp
fabric|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/fabric/egg-fabric.yaml|tcp
forge|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/forge/egg-forge-minecraft.yaml|tcp
neoforge|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/neoforge/egg-neo-forge.json|tcp
quilt|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/quilt/egg-quilt.yaml|tcp
velocity|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/proxy/java/velocity/egg-velocity.json|tcp
bungeecord|https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/proxy/java/bungeecord/egg-bungeecord.yaml|tcp
pumpkin|file:eggs/pumpkin.yaml|tcp
EOF
}

egg_selected() {
  local want
  want=$(echo "$EXTRA_EGGS" | tr ',' '\n')
  local line name url proto
  while IFS='|' read -r name url proto; do
    [ -n "$name" ] || continue
    case "$name" in
      \#*) continue ;;
    esac
    local pick
    for pick in $want; do
      case "$pick" in
        games)
          case "$name" in
            rust|valheim|7-days-to-die|counter-strike-2|counter-strike-source|team-fortress-2|garrys-mod|palworld|satisfactory|terraria|factorio|fivem)
              echo "$name|$url" ;;
          esac
          ;;
        bots)
          case "$name" in
            discord-*) echo "$name|$url" ;;
          esac
          ;;
        runtimes)
          case "$name" in
            python|nodejs|rust-lang) echo "$name|$url" ;;
          esac
          ;;
        minecraft)
          case "$name" in
            paper|purpur|folia|vanilla|fabric|forge|neoforge|quilt|velocity|bungeecord|pumpkin)
              echo "$name|$url" ;;
          esac
          ;;
        all) echo "$name|$url" ;;
      esac
    done
  done <<EOF
$(egg_catalog)
EOF
}

eggs_phase() {
  banner "Phase 15 - Importing extra eggs ($EXTRA_EGGS)"
  ensure_service pelican-queue 5 || log_err "Queue worker not running - egg installs will wait in the queue."

  ensure_app_api_key || {
    log_err "No panel API key available - eggs skipped (rerun the installer later)."
    return 0
  }

  # One paginated fetch of the panel's egg identities for the idempotency
  # checks (uuid first, name-slug fallback - upstream egg names change).
  local egg_list page count
  egg_list=$(mktemp)
  for page in 1 2 3 4 5 6 7 8 9 10; do
    app_api GET "/eggs?per_page=100&page=$page"
    if [ "$APP_CODE" != "200" ]; then
      break
    fi
    echo "$APP_RESP" | jq -r '.data[]? | "\(.attributes.uuid // "") \(.attributes.name // "" | ascii_downcase | gsub("[^a-z0-9-]"; "-"))"' 2>/dev/null >> "$egg_list" || true
    count=$(echo "$APP_RESP" | jq '.data | length' 2>/dev/null || echo 0)
    [ "$count" -lt 100 ] && break
  done

  local count_imported=0
  local name url
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    log "Importing egg '$name' from $url"
    local code raw egg_tmp uuid slug
    egg_tmp=$(mktemp)
    case "$url" in
      file:*)
        local local_egg="$SCRIPT_DIR/${url#file:}"
        if [ ! -f "$local_egg" ]; then
          rm -f "$egg_tmp"
          log_err "Vendored egg '$name' missing at $local_egg"
          continue
        fi
        cp -f "$local_egg" "$egg_tmp"
        ;;
      *)
        if ! run_with_heartbeat "egg download ($name)" 120 curl -fsSL -m 60 -o "$egg_tmp" "$url"; then
          rm -f "$egg_tmp"
          log_err "Could not download egg '$name' from $url"
          continue
        fi
        ;;
    esac
    uuid=$(egg_uuid_from_file "$egg_tmp")
    slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sed 's/[^a-z0-9-]/-/g')
    if egg_already_imported "$egg_list" "$uuid" "$slug"; then
      log "Egg '$name' already imported."
      rm -f "$egg_tmp"
      continue
    fi
    app_api_raw_file POST /eggs/import "$egg_tmp" >/dev/null
    code=${APP_CODE:-}
    raw=${APP_RESP_RAW:-}
    rm -f "$egg_tmp"
    case "$code" in
      201|200)
        log "Egg '$name' imported."
        count_imported=$((count_imported + 1))
        ;;
      422|400)
        log_err "Egg '$name' rejected by panel (bad format?): ${raw:0:300}"
        ;;
      *)
        log_err "Egg '$name' import failed (HTTP ${code:-none}): ${raw:0:300}"
        ;;
    esac
    sleep 1
  done <<EOF
$(egg_selected)
EOF
  rm -f "$egg_list"
  log "Extra eggs processed: $count_imported imported."
}

egg_uuid_from_file() {
  # uuid of a PLCN_v3 yaml (top-level `uuid:`) or pterodactyl json egg.
  local u
  u=$(sed -n 's/^uuid:[[:space:]]*//p' "$1" 2>/dev/null | head -1 | sed -e "s/['\"]//g")
  if [ -z "$u" ]; then
    u=$(sed -n 's/^[[:space:]]*"uuid":[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1)
  fi
  printf '%s' "$u"
}

egg_already_imported() {
  # $1 = uuid/slug list, $2 = egg uuid (may be empty), $3 = our name slug
  local listfile=$1 uuid=$2 slug=$3
  [ -s "$listfile" ] || return 1
  if [ -n "$uuid" ] && grep -qF "$uuid " "$listfile"; then
    return 0
  fi
  if [ -n "$slug" ] && grep -qE " ${slug}$" "$listfile"; then
    return 0
  fi
  return 1
}