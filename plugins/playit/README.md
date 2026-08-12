# Playit plugin (skeleton, WIP)

Shows playit.gg tunnel addresses in the Pelican server panel and automates
tunnel creation for allocations.

## Status
- **Agent**: deployed on the server as `playit-agent` docker container
  (`docker run -d --restart unless-stopped --net=host -e SECRET_KEY=...`).
  Connected + account verified.
- **Tunnels**: created manually in the playit.gg dashboard (see below) until
  the API integration is finished.
- **Plugin**: skeleton only. Next steps:
  1. Settings page (`HasPluginSettings` + `EnvironmentWriterTrait`)
     for `PLAYIT_API_KEY` (https://playit.gg -> Account -> API keys).
  2. Fetch tunnels from the playit API; map allocation port -> public address.
  3. Server-panel widget showing the address (register via
     `Console::registerCustomWidgets` or a server page).
  4. Admin action "create playit tunnel" for a node's allocations.
  5. Build zip, host, add to `lib/plugins.sh` PLUGIN_LIST.

## Manual tunnel setup (do this now)
1. https://playit.gg -> sign in -> **Manage** (or Tunnels).
2. **New Tunnel** -> TCP -> Local address `192.168.10.41`, port `25565`
   (repeat for 25566..25575 as needed).
3. playit gives each tunnel a public address like `xxxx.playit.gg:NNNNN`.
4. Players join that address in Minecraft.

Note: playit free tier = TCP (Minecraft Java works). UDP needs premium.

## Agent reference
- Image: `ghcr.io/playit-cloud/playit-agent:1.0`
- Secret key: stored in the container env (`SECRET_KEY`).
- Local socket: `/run/playit/playitd.sock` (inside container, host network).
- Logs: `docker logs playit-agent`
