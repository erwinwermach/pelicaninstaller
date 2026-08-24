# Pelican Plugins (self-developed)

Built and shipped as zips via GitHub Actions (rolling `plugins-latest`
release). `lib/plugins.sh` imports them automatically on every fresh
install via `https://github.com/erwinwermach/pelicaninstaller/releases/latest/download/<id>.zip`.

## opsboard

All-in-one operations board, replaces the former crashlog/health/playit
plugins (one plugin = one discovery pass = less panel overhead).

- Admin pages: **System Health** (services, disk, jars), **Crashlogs**
  (paginated timeline, filters, mclo.gs upload), **Routing** (backends +
  per-port addresses).
- Server pages: **Health** (jar status + schedule repair), **Crashlogs**,
  **Connections** (join addresses per allocation with copy buttons).
- Console widget: join addresses above the console.

Data sources (written by the host watchdog, world-readable under
`storage/app/`): `pelican-health.json`, `pelican-jars.json`,
`crashlog/*`, `routes.json`.

Performance rules for this plugin: timelines render 50 events per page
server-side; excerpts decode on demand only; no polling; no custom CSS
(only Filament components so it always matches the active theme).

## perfctl

Recommend-only startup-flag tuner. The watchdog (`lib/perfctl.sh`)
detects each server's workload from egg name/docker image/startup:

| Profile | Matches |
|---|---|
| mc-paper | PaperMC/Purpur/Pufferfish/Leaves |
| mc-fabric / mc-forge | modded loaders |
| mc-generic | vanilla & other Java Minecraft |
| proxy-java | Velocity/Waterfall/BungeeCord |
| source-engine | CS/GMod/TF2/L4D (srcds) |
| python | Python yolks/startups |
| nodejs | Node.js yolks/startups |

Java recommendations are Aikar-style G1 sets sized to the allocation
(Xms=Xmx at ~72 %, clamped 512 MB–12 GB, region size scales at ≥12 GB).

**Nothing is applied automatically.** The server's Performance page shows
current vs recommended startup; *Apply* writes a request file that the
watchdog executes within 5 minutes (original command backed up,
*Revert* restores it).

## Building locally

```bash
bash bin/build-plugins.sh   # -> dist/<id>.zip
```

Zip layout: archive root contains `<plugin-id>/` with `plugin.json` inside.
