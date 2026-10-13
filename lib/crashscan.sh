CRASHLOG_DIR="/var/www/pelican/storage/app/crashlog"

crash_scan() {
  command -v python3 >/dev/null 2>&1 || return 0
  [ -d /var/www/pelican ] || return 0
  mkdir -p "$CRASHLOG_DIR/events" "$CRASHLOG_DIR/state"
  if run_with_heartbeat "crash scan" 900 python3 "$HEAL_DIR/lib/crashscan.py"; then
    # Only chown when something is actually misowned - a blind -R over the
    # whole tree ran on every heal cycle otherwise.
    if [ -n "$(find "$CRASHLOG_DIR" ! -user www-data -print -quit 2>/dev/null)" ]; then
      chown -R www-data:www-data "$CRASHLOG_DIR" 2>/dev/null || true
    fi
  fi
  return 0
}
