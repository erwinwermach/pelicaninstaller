<?php

return [
    // playit.gg API key (https://playit.gg -> Account -> API keys).
    // Used for live address lookup; tunnel creation is done host-side
    // (installer/heal) so the panel only needs read access.
    'api_key' => env('PLAYIT_API_KEY', ''),

    // Files written by the host-side playit enforcer:
    // tunnels: {"25565": "xxx.tun.ply.gg", ...}  (port -> public address)
    // status:  {"has_premium": bool, ...}
    'tunnels_file' => env('PLAYIT_TUNNELS_FILE', '/etc/pelican-installer/playit-tunnels.json'),
    'status_file' => env('PLAYIT_STATUS_FILE', '/etc/pelican-installer/playit-status.json'),

    // The playit agent's local IPC socket (agent CLI)
    'agent_socket' => env('PLAYIT_AGENT_SOCKET', '/run/playit/playitd.sock'),
];
