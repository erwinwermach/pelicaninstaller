# Pelican Panel + Wings — fully automatic installer (Cloudflare Zero Trust + free game routing)

One-line installer for **Pelican Panel + Wings + every dependency** on a single
Ubuntu Server 24.04 machine, tuned for **low-end hardware** (older CPUs, 16 GB
RAM) and wired up for hosting behind **CGNAT/NAT**:

- **Panel + node API** are hidden behind a **Cloudflare Zero Trust tunnel**
  (`panel.yourdomain.com`, `node.yourdomain.com`) — no inbound ports needed.
  If a previous install already exists in your Cloudflare account, the
  installer detects it and asks: **reuse, replace, or wipe clean**.
- **Game servers** (Minecraft etc.) always show **direct connection addresses**
  (LAN + public IP, if reachable) on each server's Connections page — players
  can join immediately on a LAN, VPN or a forwarded port. Optional tunnel
  backends add public addresses when they work (see `GAME_ROUTING`), and if a
  backend fails or is unconfigured, the direct addresses remain. Game routing
  is **not** a required install-time decision anymore.

  | Backend | Cost | Stability | Notes |
  |---|---|---|---|
  | `playit` (default) | free | good | playit.gg game-type tunnels; automatic |
  | `bore` | free | best-effort | open-source client vs the free `bore.pub` relay; address port changes whenever its service restarts |
  | `frp-vps` | free* | rock solid | uses **your own** free-tier VPS (e.g. Oracle Cloud Always Free) as relay — you provide SSH access once |
  | `direct` | free | n/a behind CGNAT | real router port-forwarding/UPnP; only works when your connection is NOT behind CGNAT |
  | `none` | free | always | direct addresses only |

  Backends are configured via `GAME_ROUTING` in the config file — never asked
  during install. Direct LAN/public addresses are always merged into the panel
  regardless of backend, so players keep a fallback even when a tunnel fails.
  UDP-aware: playit free tier creates TCP game tunnels (UDP needs premium or
  the frp/direct backends); the watchdog detects UDP-heavy eggs and creates
  `custom-udp` tunnels automatically on premium accounts.

## Included eggs (imported automatically)

The installer imports a curated set of eggs from the community pelican-eggs
repos (`EXTRA_EGGS=games,bots` by default, configurable):

- **Games (SteamCMD/standalone):** Rust, Valheim, 7 Days to Die, CS2,
  CS:Source, TF2, GMod, Palworld, Satisfactory, Terraria, Factorio, FiveM
- **Bots:** Discord bots (Red, Ree6)
- **Runtimes:** generic Python, NodeJS, Rust — for your own scripts and bots

These import **idempotently** (skipped if already present) at install and
during the weekly self-update.

  *Why not ngrok/zrok/Tailscale-Funnel? Verified dead ends for games: ngrok
  free caps at 1 GB/month transfer, zrok raw TCP is private-share-only,
  Tailscale Funnel serves TLS on ports 443/8443/10000 only (no raw game
  protocols). TCPShield is a solid Minecraft-specific option but requires
  moving your DNS away from Cloudflare — documented here, not automated.
- **HTTP apps** (Python/JS/Discord bots, web servers) route through the tunnel
  as `app-<port>.yourdomain.com` (`CF_APP_ROUTING=yes`).

Everything is automatic: OS/panel/wings updates, tunnel/DNS/cert repair,
game-tunnel mapping, service recovery — running 24/7 via systemd.

## Install

### Requirements
- Ubuntu Server 24.04 (24.04.x) — the installer refuses to run on anything else.
- A domain on **Cloudflare** (zone active).
- A **Cloudflare API token** (https://dash.cloudflare.com/profile/api-tokens →
  Create Custom Token): Zone → Zone/DNS/SSL-and-Certificates (Read/Edit/Edit),
  Account → Cloudflare Tunnel (Edit).
- Backend-dependent extras:
  - `playit`: a playit.gg secret key (https://playit.gg → Account → Secret Key).
  - `frp-vps`: SSH access to any small VPS with a public IP.
  - `bore`: nothing — works instantly.

### Run (one line)
```bash
curl -fsSL https://raw.githubusercontent.com/erwinwermach/pelicaninstaller/main/install.sh | sudo bash
```

You are asked once for: domain, Cloudflare token, timezone, subdomains,
game-port range, an optional playit.gg key, node name, and whether to do a
full clean-slate reset first. Game routing is no longer an install question —
the panel always shows direct connection addresses for every game port, and
tunnel backends (playit/bore/frp) are added later via `GAME_ROUTING` in the
config. A confirmed reset removes everything this installer manages — panel/web/database/Docker/game-tunnel data **plus** its own
config/stages/secrets — and re-downloads the installer fresh from GitHub, so
no stale configuration (e.g. a corrupted token) can survive into the new
setup. The OS, SSH, your user accounts and files are never touched.
Everything is saved to `/etc/pelican-installer/installer.conf` (root-only)
and reused forever.
For unattended runs, pre-fill that file (see `installer.conf.example`):

```bash
curl -fsSL https://raw.githubusercontent.com/erwinwermach/pelicaninstaller/main/install.sh | sudo bash -s -- --config /path/to/installer.conf
```

If the installer finds an existing Pelican tunnel/DNS from an earlier install
(e.g. you moved to new hardware), it checks whether that tunnel still has live
connectors:
- **offline (no connectors)** → the old tunnel and its DNS records are deleted
  and a fresh one is created **automatically** — you don't have to do anything
  to take over from a dead server.
- **live (another server still running it)** → you are asked:
  **R** reuse it · **F** replace it · **W** wipe all managed resources ·
  **A** abort. Unattended runs default to reuse (`CF_EXISTING=reuse|replace|clean`
  to force a policy; tunnels with other names are never touched).

### After install
- **Complete the setup wizard** at `https://panel.yourdomain.com/installer` —
  it walks you through database/queue checks, creates your admin account, and
  lets you **pick eggs to install** (that's why the panel is fully populated
  afterwards). The installer waits for you to finish this step before
  continuing, so everything (node bootstrap, plugins, routing) is ready when
  the wizard completes. (Set `AUTO_ADMIN=yes` in the config to have the
  installer create the admin automatically instead.)
- Create a game server → open its **Connections** page: public addresses for
  each allocation appear automatically within ~10 minutes (watchdog syncs).
  The console widget shows them too. Players join those addresses.
- Open the server's **Performance** page: it detects the workload type
  (PaperMC, Forge/Fabric, Source engine, Python, Node.js, proxies) and proposes
  startup flags sized to the server's memory limit — **nothing is applied
  automatically**, review and click *Apply* (one-click revert included).
- HTTP apps: set `CF_APP_ROUTING=yes`, re-run the installer.

## Included panel plugins (installed automatically)

| Plugin | What it does |
|---|---|
| **Ops Board** | Admin: system health, crashlog timeline (paginated, mclo.gs upload), routing overview. Server: health + egg info + one-click jar repair, crashlogs, connection addresses + console widget |
| **Performance** | Per-server workload detection and recommend-only startup-flag tuning (apply/revert manually) |
| Modpack Manager | Install/update Minecraft modpacks (CurseForge, Modrinth, FTB, ATLauncher) |
| Minecraft Modrinth | Install/update mods & plugins from Modrinth |
| Mclogs Uploader | Share server logs to mclo.gs |

Set `PANEL_PLUGINS=all|minimal|none|comma,list` to control hub plugins
(default `minimal`). Our own two plugins always install unless
`INSTALL_SELF_PLUGINS=no`.

## Low-end hardware tuning (built in)

Applied automatically as phase 9 (also retro-fitted onto existing installs):
- PHP opcache + on-demand FPM workers sized to RAM, JIT off
- MariaDB buffer pool capped (25 % of RAM, max 512 MB), skip-name-resolve
- Redis memory cap (512 MB, noeviction — queue-safe)
- nginx gzip + static asset caching + open_file_cache
- Docker json-file log rotation (10 MB × 3) + live-restore
- Panel caches prebuilt (`artisan optimize`, `filament:optimize`, `icons:cache`)
- Self-heal split into light checks (5 min) and deep Cloudflare reconcile (30 min)
- Watchdog file scans gated by change detection (no full-volume sweeps)

## Automatic updates & self-healing

| What | When |
|------|------|
| Ubuntu security + full upgrades | daily / weekly (auto-reboot handled) |
| Pelican Panel + Wings + cloudflared updates | weekly |
| Installer scripts self-update | every run + weekly |
| Service recovery (mariadb/redis/php/nginx/docker/cloudflared/wings/queue) | every 5 min + on boot |
| Tunnel/service/certificate repair | every 5 min (light) |
| Full tunnel+DNS reconcile | every 30 min |
| Game-routing address refresh | every 10 min |

Manual: `sudo bash /opt/pelican-installer/installer.sh` (resumes unfinished
phases), `sudo /opt/pelican-installer/bin/heal.sh`, `.../bin/update.sh`.

## Network reality

Most home connections sit behind CGNAT — direct port forwarding is useless and
game ports cannot traverse a Cloudflare tunnel publicly (HTTP only). Hence the
outbound-tunnel backends above; the firewall exposes SSH plus LAN access, and
only opens real game ports when a usable public IP exists.

## Notes

- Pelican is in beta: the panel's web installer (`/installer`) is broken
  (Livewire redirects while uninstalled) — this installer completes the setup
  via the panel CLI instead (admin account, APP_INSTALLED, queue worker, eggs,
  modern Java images).
- Logs: `/var/log/pelican/` (install.log, heal.log, update.log).
- Troubleshooting: check `systemctl status <service>`, the heal log, and
  `/var/log/pelican/install.log`; rerunning the installer resumes where it
  stopped.

## Links

- Pelican docs: https://pelican.dev/docs
- playit.gg: https://playit.gg
- bore: https://github.com/ekzhang/bore
- frp: https://github.com/fatedier/frp
- Cloudflare API tokens: https://dash.cloudflare.com/profile/api-tokens
