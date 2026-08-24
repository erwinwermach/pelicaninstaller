queue_phase() {
  banner "Phase 10 - Panel queue worker + scheduler"
  log "Installing panel queue worker (required for installs and plugins)..."
  cat > /etc/systemd/system/pelican-queue.service <<EOF
[Unit]
Description=Pelican Panel Queue Worker
After=network-online.target redis-server.service
Wants=network-online.target

[Service]
User=www-data
WorkingDirectory=/var/www/pelican
ExecStart=/usr/bin/php /var/www/pelican/artisan queue:work redis --sleep=3 --tries=3 --timeout=60 --max-time=3600
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ensure_service pelican-queue 5 || log_err "Queue worker failed to start."

  log "Installing scheduler cron entry..."
  (crontab -l -u www-data 2>/dev/null | grep -v 'artisan schedule:run'; \
    echo '* * * * * cd /var/www/pelican && /usr/bin/php artisan schedule:run >> /dev/null 2>&1') \
    | crontab -u www-data - 2>/dev/null || true

  log "Queue worker and scheduler active."
}
