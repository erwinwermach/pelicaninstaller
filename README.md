# Pelican Panel + Wings + Cloudflare Zero Trust — fully automatic installer

Installs **Pelican Panel + Wings + every dependency** on a single Ubuntu Server 24.04
machine, wires it up behind **Cloudflare Zero Trust** (no open inbound ports except SSH),
and then **keeps everything alive, updated and self-healing forever**.

The only thing you ever do manually: create the admin account at
`https://panel.yourdomain.com/installer` after the install. That's it.

## Install

### Requirements
- **Ubuntu Server 24.04 (24.04.x)** — the installer refuses to run on anything else.
- A domain on your **Cloudflare** account (zone must be active).
- A **Cloudflare API token** (see below) — created once, takes 2 minutes.

### 1. Create the Cloudflare API token
Go to **https://dash.cloudflare.com/profile/api-tokens** → *Create Token* →
*Create Custom Token*. Permissions:

| Scope | Permission | Level |
|-------|-----------|-------|
| Account | Cloudflare Tunnel | Edit |
| Zone | Zone | Read |
| Zone | DNS | Edit |
| Zone | SSL and Certificates | Edit |

Zone Resources: *Include → Specific zone → your domain*.
Account Resources: *Include → your account*.

Note: the token does **not** need the "Account Settings: Read" permission —
the installer derives your Account ID automatically from your zone. Only add
`CF_ACCOUNT_ID` to the config file if the installer still cannot determine it
(https://dash.cloudflare.com → right sidebar → *Account ID*).

### 2. Run the installer (one line)
SSH into your Ubuntu 24.04 server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/erwinwermach/pelicaninstaller/main/install.sh | sudo bash
```

You are asked **once** for: domain, Cloudflare API token, timezone, subdomains,
game-port range and node name. Everything is saved to
`/etc/pelican-installer/installer.conf` (root-only, mode 600) and reused forever.

For a fully unattended run, pre-fill that file yourself (see `installer.conf.example`)
and run:

```bash
curl -fsSL https://raw.githubusercontent.com/erwinwermach/pelicaninstaller/main/install.sh | sudo bash -s -- --config /path/to/installer.conf
```

Or, if you have the files on the machine already: `sudo bash installer.sh`.

### 3. Create the admin account (the ONLY manual step)
After the install finishes (and the server reboots itself), open:

```
https://panel.yourdomain.com/installer
```

Create the admin account. **Within ~5 minutes** the self-heal system notices it,
creates the Wings node, allocates your game ports, writes `/etc/pelican/config.yml`
and starts Wings. Check it in the panel: *Admin → Nodes* → your node → *green dot*.

## What you end up with

- Panel: `https://panel.yourdomain.com`
- Node API: `https://node.yourdomain.com` (tunneled, plain HTTP origin behind proxy)
- Game port `25565` → `game-25565.yourdomain.com` (players join the hostname; TCP+UDP)
- SFTP (port 2022) → tunneled via `node.yourdomain.com:2022`
- Inbound firewall: **only SSH**. Nothing else is reachable from the internet.

## Automatic updates & self-healing

Everything below runs by itself — you do nothing:

| What | When | How |
|------|------|-----|
| Ubuntu security patches | daily | `unattended-upgrades` (auto-reboots when needed) |
| Ubuntu full upgrade | weekly | `pelican-update.timer` (Monday 04:00, randomized) |
| Pelican Panel update | weekly | maintenance mode → download → composer → migrate → optimize |
| Wings + cloudflared update | weekly | latest binary downloaded, service restarted |
| Docker cleanup | weekly | dangling images pruned |
| **Installer scripts update** | weekly + every run | fetches `VERSION` from GitHub; newer version replaces itself |
| Service recovery | every 5 min + on boot | any dead service (mariadb/redis/php-fpm/nginx/docker/cloudflared/wings) restarted |
| Tunnel recovery | every 5 min | tunnel + credentials re-created if lost |
| DNS recovery | every 5 min | CNAME records re-pointed to the tunnel if deleted/changed |
| Certificate renewal | before expiry | Cloudflare Origin CA certificates re-issued |
| Wings node bootstrap | within ~5 min of `/installer` | node + allocations + config.yml created automatically |

The installer scripts at `/opt/pelican-installer` update themselves: each time you run
the installer, and weekly via the update timer, they compare the local `VERSION` file
against the GitHub `main` branch and replace themselves with the newer version.

Manual control:

```bash
sudo bash /opt/pelican-installer/installer.sh --update        # update installer scripts only
sudo bash /opt/pelican-installer/installer.sh                 # run/resume the installer
sudo bash /opt/pelican-installer/installer.sh --no-self-update
sudo /opt/pelican-installer/bin/heal.sh                       # run self-heal now
sudo /opt/pelican-installer/bin/update.sh                     # run all updates now
```

## Useful commands

| What | Command |
|------|---------|
| Install logs | `/var/log/pelican/install.log` |
| Heal logs | `/var/log/pelican/heal.log` |
| Update logs | `/var/log/pelican/update.log` |
| Wings status | `systemctl status wings` / `journalctl -u wings -f` |
| Tunnel status | `systemctl status cloudflared` |
| Config | `/etc/pelican-installer/installer.conf` |
| Resize node resources | edit `NODE_MEMORY`/`NODE_DISK` in the config, rerun installer |

## What the installer does (fully automatic)

1. **Clean slate** — stops and purges any old docker/nginx/apache/php/mysql/panel/wings,
   wipes their data, cleans apt. OS, SSH and user accounts stay intact.
2. **Updates Ubuntu** — full upgrade, security auto-upgrades, 2 GB swap if missing,
   fail2ban, timezone.
3. **Installs the stack** — PHP 8.3 + extensions, MariaDB, Redis, Nginx, Composer,
   the latest Pelican Panel, auto-creates the database and writes the `.env` for you.
4. **Cloudflare Zero Trust** — creates a tunnel, all DNS records
   (`panel.X`, `node.X`, `game-<port>.X`), TCP+UDP tunnel routes for every game port,
   Cloudflare Origin CA certificates, starts `cloudflared`.
5. **Docker + Wings** — Docker CE, Wings binary, hardened systemd service.
6. **Firewall** — deny all inbound except SSH. Game ports are bound to loopback only
   and served through the tunnel — your server IP stays completely hidden.
7. **Self-heal + auto-update system** — systemd timers, logrotate, watchdog.

## Notes

- Pelican is in beta; the installer verifies every API response and the self-heal
  system retries automatically if something drifts.
- The wipe phase purges old docker/nginx/php/mysql/panel installations and their data.
  It does **not** touch the OS itself, SSH or `/home`.
- Your API token is stored at `/etc/pelican-installer/installer.conf` (root-only read).
- Flags: `--config FILE`, `--no-reboot`, `--skip-wipe`, `--no-self-update`, `--update`.

## Troubleshooting

- **`/installer` doesn't load**: wait for the reboot + heal cycle (up to 2 min),
  check `systemctl status cloudflared` and `/var/log/pelican/heal.log`.
- **Token rejected**: recreate the token with the permissions above (Zone DNS Edit is
  the one that's most often missing).
- **"Could not determine account id"**: add `CF_ACCOUNT_ID` to the config file.
- **Wings not starting**: `journalctl -u wings -f` — usually a config.yml issue; delete
  `/etc/pelican/config.yml` and let the heal system regenerate it.

## Links

- Repo: https://github.com/erwinwermach/pelicaninstaller
- Pelican docs: https://pelican.dev/docs
- Cloudflare API tokens: https://dash.cloudflare.com/profile/api-tokens
- Cloudflare Zero Trust: https://one.dash.cloudflare.com
