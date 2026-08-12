playit_phase() {
  if [ -z "${PLAYIT_SECRET_KEY:-}" ]; then
    log "No PLAYIT_SECRET_KEY configured - playit agent skipped (add it to $CONF_FILE to enable)."
    return 0
  fi
  banner "Phase - Deploying playit.gg agent"
  docker rm -f playit-agent >/dev/null 2>&1 || true
  docker run -d --restart unless-stopped --name playit-agent --net=host \
    -e SECRET_KEY="$PLAYIT_SECRET_KEY" \
    ghcr.io/playit-cloud/playit-agent:1.0 >>"$INSTALL_LOG" 2>&1 || {
    log_err "playit agent failed to start - check 'docker logs playit-agent'."
    return 0
  }
  sleep 6
  if docker ps --format '{{.Names}}' | grep -qx playit-agent; then
    log "playit agent running (create TCP tunnels at https://playit.gg -> Tunnels)."
  fi
}
