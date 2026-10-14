EXTRA_EGGS=${EXTRA_EGGS:-games,bots}

egg_catalog() {
  cat <<'EOF'
# steamcmd games (UDP-heavy where noted)
rust|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/rust/vanilla/egg-rust.yaml|udp
valheim|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/valheim/valheim_vanilla/egg-valheim.json|udp
7-days-to-die|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/7_days_to_die/egg-7-days-to-die.json|udp
counter-strike-2|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/counter_strike/counter_strike_2/egg-counter--strike--2.yaml|udp
counter-strike-source|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/counter_strike/counter_strike_source/egg-counter--strike--source.yaml|udp
team-fortress-2|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/team_fortress_2/egg-team-fortress-2.json|udp
garrys-mod|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/garrysmod/egg-garry-s-mod.json|udp
palworld|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/palworld/egg-palworld.json|udp
satisfactory|https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/refs/heads/main/satisfactory/egg-satisfactory.json|tcp
# standalone games
terraria|https://raw.githubusercontent.com/pelican-eggs/games-standalone/refs/heads/main/terraria/egg-terraria.json|tcp
factorio|https://raw.githubusercontent.com/pelican-eggs/games-standalone/refs/heads/main/factorio/egg-factorio.json|tcp
fivem|https://raw.githubusercontent.com/pelican-eggs/games-standalone/refs/heads/main/fivem/egg-fivem.json|tcp
# generic runtimes (bots, apps, scripts)
python|https://raw.githubusercontent.com/pelican-eggs/generic/refs/heads/main/python/egg-python-generic.json|tcp
nodejs|https://raw.githubusercontent.com/pelican-eggs/generic/refs/heads/main/nodejs/egg-node-js-generic.json|tcp
rust-lang|https://raw.githubusercontent.com/pelican-eggs/generic/refs/heads/main/rust/egg-rust-generic.json|tcp
# discord bots
discord-red|https://raw.githubusercontent.com/pelican-eggs/chatbots/refs/heads/main/discord/redbot/egg-red.json|tcp
discord-ree6|https://raw.githubusercontent.com/pelican-eggs/chatbots/refs/heads/main/discord/ree6/egg-ree6.json|tcp
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

  local count=0
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    if egg_already_imported "$name"; then
      continue
    fi
    log "Importing egg '$name' from $url"
    local body code egg_tmp
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
    body=$(cat "$egg_tmp")
    rm -f "$egg_tmp"
    code=$(app_api_raw POST /eggs/import "$body")
    case "$code" in
      201|200)
        log "Egg '$name' imported."
        count=$((count + 1))
        ;;
      422|400)
        log_err "Egg '$name' rejected by panel (bad format?): $APP_RESP_RAW"
        ;;
      *)
        log_err "Egg '$name' import failed (HTTP $code): $APP_RESP_RAW"
        ;;
    esac
    sleep 1
  done <<EOF
$(egg_selected)
EOF
  log "Extra eggs processed: $count imported."
}

egg_already_imported() {
  local name=$1 slug
  slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sed 's/[^a-z0-9-]/-/g')
  app_api GET "/eggs?per_page=100"
  echo "$APP_RESP" | jq -e --arg s "$slug" \
    '.data[]? | select((.attributes.name // "" | ascii_downcase | gsub("[^a-z0-9-]"; "-")) == $s)' >/dev/null 2>&1
}