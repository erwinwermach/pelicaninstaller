# Crash Logs

Universal crash logger for Pelican Panel. Detects crashes for **every egg/game server**
plus panel and host infrastructure, keeps a 30-day audit trail, tries to point out the
issue automatically and exports logs for manual review.

## How it works

The host watchdog (`bin/heal.sh`, runs every 5 minutes) scans:

- **Server containers** (any egg): exited containers with a non-zero exit code, OOM kills
  and crash/restart loops — log excerpt comes from the container console.
- **Game crash artifacts**: `crash-reports/*.txt` and `hs_err_pid*.log` inside server volumes.
- **Panel**: `laravel.log` errors (incremental scan, no full reads).
- **Wings + infrastructure**: mariadb, redis, php-fpm, nginx, docker, cloudflared and the
  queue worker via the systemd journal (warning or worse).

Everything is incremental (byte offsets, timestamps, restart counters) and excerpts are
gzip-compressed when that actually saves space. Events older than 30 days are pruned
automatically.

## Pages

- **Server panel → Crash Logs**: crash history for that server, detected issue hints,
  expandable log excerpts, per-event and bulk export.
- **Admin panel → Crash Logs**: global audit log for all servers, panel, wings and
  services with filters, stats and a full export.

## Storage

State lives in `/var/www/pelican/storage/app/crashlog/` (written by the watchdog as root,
read-only for the panel):

- `index-server-<uuid>.json` — per-server event index (latest 100)
- `index-infra.json` — panel/wings/service events (latest 200)
- `audit.json` — global audit trail (latest 400)
- `events/<id>.json` — full event including the compressed excerpt
- `state/` — scanner cursors (offsets, restart counters, journal timestamps)
