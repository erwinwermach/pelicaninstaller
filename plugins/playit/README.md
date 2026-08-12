# Playit plugin

Shows playit.gg tunnel addresses in the Pelican server panel and automates
tunnel creation for allocations.

## Status
- **Agent**: deployed on the server as `playit-agent` docker container
  (docker restart policy, host networking, secret key in env). Connected + verified.
- **Tunnels (auto)**: when `PLAYIT_API_KEY` is configured, the installer/heal
  calls the playit API (`POST https://api.playit.gg/v1/...`):
  - `/v1/agents/rundata` -> agent id + existing tunnels
  - `/v1/tunnels/create` -> one TCP tunnel per allocation, named `pelican-<port>`
  - writes `port -> display_address` to
    `/etc/pelican-installer/playit-tunnels.json` (chmod 644, read by the panel)
- **Plugin**: server-panel "Playit" page listing each allocation's public join
  address (reads the map file). Plugin settings (`HasPluginSettings`) store
  `PLAYIT_API_KEY` in `.env`.
- Free tier = TCP (Minecraft Java works). UDP needs playit premium - the
  create call uses `custom-tcp`; premium can switch to `custom-both` per tunnel.

## Manual tunnel setup (fallback, no API key)
1. https://playit.gg -> sign in -> **Tunnels**
2. **New Tunnel** -> TCP -> Local address `<server-lan-ip>`, port `25565`
   (repeat for 25566..25575 as needed).
3. Players join the assigned `xxxx.playit.gg:NNNNN` address.

## Agent reference
- Image: `ghcr.io/playit-cloud/playit-agent:1.0`
- Secret key: container env `SECRET_KEY`.
- Logs: `docker logs playit-agent`
- API base: `https://api.playit.gg`, auth `Authorization: Bearer <api key>`.
