# Pelican Panel + Wings — fully automatic installer (Cloudflare + playit.gg)

One-line installer for **Pelican Panel + Wings + every dependency** on a single
Ubuntu Server 24.04 machine, wired up for hosting behind **CGNAT/NAT**:

- **Panel + node API** are hidden behind a **Cloudflare Zero Trust tunnel**
  (`panel.yourdomain.com`, `node.yourdomain.com`) — no inbound ports needed.
- **Game servers** (Minecraft etc.) are exposed through **playit.gg** — free
  game-type tunnels that work through CGNAT, with a panel plugin that shows
  each server's public playit address instead of an IP.
- **HTTP apps** (Python/JS/Node/Discord bots, web servers) can be routed
  through the Cloudflare tunnel as `app-<port>.yourdomain.com`
  (`CF_APP_ROUTING=yes`).

Everything is automatic: OS/panel/wings updates, tunnel/DNS/cert repair,
playit tunnel mapping, service recovery — running 24/7 via systemd.

## Install

### Requirements
- Ubuntu Server 24.04 (24.04.x) — the installer refuses to run on anything else.
- A domain on **Cloudflare** (zone active).
- A **Cloudflare API token** (https://dash.cloudflare.com/profile/api-tokens →
  Create Custom Token): Zone → Zone/DNS/SSL-and-Certificates (Read/Edit/Edit),
  Account → Cloudflare Tunnel (Edit). The token does **not** need Account
  Settings: Read — the account id is derived from your zone automatically.
- Optional: a **playit.gg secret key** (https://playit.gg → Account → Secret
  Key) to enable the game-tunnel integration.

### Run (one line)
```bash
curl -fsSL https://raw.githubusercontent.com/erwinwermach/pelicaninstaller/main/install.sh | sudo bash
```

You are asked once for: domain, Cloudflare token, timezone, subdomains,
game-port range, node name, playit secret key (optional). Everything is saved
to `/etc/pelican-installer/installer.conf` (root-only) and reused forever.
For unattended runs, pre-fill that file (see `installer.conf.example`):

```bash
curl -fsSL https://raw.githubusercontent.com/erwinwermach/pelicaninstaller/main/install.sh | sudo bash -s -- --config /path/to/installer.conf
```

### After install
- Log in at `https://panel.yourdomain.com` — the admin account is created
  automatically during install (credentials in
  `/etc/pelican-installer/secrets.env`; change the password after login).
- Create a game server in the panel → open its **Playit** page → create a
  playit tunnel for the port (free tier: game types like Minecraft Java) →
  the public address appears there automatically within 10 minutes. Players
  join that address; your real IP stays hidden.
- HTTP apps on Cloudflare-supported ports (80/443/8080/8443/2052-2087/2095-2096):
  set `CF_APP_ROUTING=yes` in the config, restart the installer phase
  (`sudo bash /opt/pelican-installer/installer.sh`) → app served at
  `app-<port>.yourdomain.com`.

## Included panel plugins (installed automatically)

| Plugin | What it does |
|---|---|
| **Playit** | Shows each server's playit.gg public address in the server panel; free/premium tier detection; create-tunnel links |
| Modpack Manager | Install/update Minecraft modpacks (CurseForge, Modrinth, FTB, ATLauncher) per server |
| Minecraft Modrinth | Install/update mods & plugins from Modrinth |
| Player Counter | Real-time player counts |
| System Status Monitor | Node CPU/RAM/disk monitoring |
| Mclogs Uploader | Share server logs to mclo.gs |

## Automatic updates & self-healing

| What | When |
|------|------|
| Ubuntu security + full upgrades | daily / weekly (auto-reboot handled) |
| Pelican Panel + Wings + cloudflared updates | weekly |
| Installer scripts self-update | every run + weekly |
| Service recovery (mariadb/redis/php/nginx/docker/cloudflared/wings/queue) | every 5 min + on boot |
| Tunnel + DNS + certificate repair | every 5 min |
| playit tunnel map refresh | every 10 min |

Manual: `sudo bash /opt/pelican-installer/installer.sh` (resumes unfinished
phases), `sudo /opt/pelican-installer/bin/heal.sh`, `.../bin/update.sh`.

## Network reality

Most home/colocated connections (this tool's main target) sit behind
CGNAT — direct port forwarding is useless and game ports cannot go through a
Cloudflare tunnel (Cloudflare only forwards HTTP ports publicly). Hence:
playit.gg for games/TCP (outbound-only, free tier = game types), Cloudflare
tunnel for the panel and HTTP apps. The firewall exposes only SSH plus the
configured game-port range for LAN play; everything else stays tunneled.

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
- Cloudflare API tokens: https://dash.cloudflare.com/profile/api-tokens
