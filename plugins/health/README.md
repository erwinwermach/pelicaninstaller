# Health & Fixer plugin

Combined panel plugin for everything the host watchdog reports:

- **Admin → System → System Health**: last heal run, disk usage, live service
  states (mariadb/redis/php/nginx/docker/cloudflared/wings/queue/playit),
  per-server jar health, playit tier + Cloudflare routing state.
- **Server → Health**: this server's jar health + one-click **Schedule repair**
  (writes a request file that the watchdog picks up within 5 minutes), the
  playit.gg join address, and the Cloudflare routing status.

## Data flow (host watchdog → panel)

The installer's heal script (`/opt/pelican-installer/bin/heal.sh`, every 5 min)
writes world-readable state files that this plugin reads:

| File | Contents |
|---|---|
| `pelican-health.json` | last_heal, disk_used, service states |
| `pelican-jars.json` | per-server jar health (jar_ok, jarfile, size, fixed) |
| `pelican-public.json` | domain, cf_app_routing |
| `playit-status.json` | has_premium, account_status |
| `playit-tunnels.json` | port → playit address |

Repair requests: the plugin writes `storage/app/requests/repair-<uuid>.req`;
the watchdog processes it and runs the jar fixer.

## Division of responsibility

- **Host-side (installer repo, stays bash/systemd):** service management,
  Cloudflare tunnel/DNS/certs, playit agent sync, firewall, queue worker,
  jar fixing (`lib/jarfix.sh`). These need root/docker and belong in the
  watchdog, not the panel.
- **Panel-side (this plugin):** surfaces all of that state, per-server views,
  and repair triggers.

## Notes

- Filament v4 quirks: `Page::$view` is non-static; `$navigationIcon` must use
  the parent's union type or be omitted.
- Install: drop into `/var/www/pelican/plugins/health` and run
  `php artisan p:plugin:install health`.
