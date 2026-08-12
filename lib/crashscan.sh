CRASHLOG_DIR="/var/www/pelican/storage/app/crashlog"

crash_scan() {
  command -v python3 >/dev/null 2>&1 || return 0
  [ -d /var/www/pelican ] || return 0
  mkdir -p "$CRASHLOG_DIR/events" "$CRASHLOG_DIR/state"
  if python3 "$HEAL_DIR/lib/crashscan.py" >>"$INSTALL_LOG" 2>&1; then
    chown -R www-data:www-data "$CRASHLOG_DIR" 2>/dev/null || true
  fi
  return 0
}
