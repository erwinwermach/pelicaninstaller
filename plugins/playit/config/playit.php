<?php

return [
    // playit.gg API key (https://playit.gg -> Account -> API keys).
    // Used for live address lookup; tunnel creation is done host-side
    // (installer/heal) so the panel only needs read access.
    'api_key' => env('PLAYIT_API_KEY', ''),

    // File written by the host-side playit enforcer:
    // {"25565": "xxx.playit.gg:12345", ...}  (port -> public address)
    'tunnels_file' => env('PLAYIT_TUNNELS_FILE', '/etc/pelican-installer/playit-tunnels.json'),

    // The playit agent's local IPC socket (agent CLI)
    'agent_socket' => env('PLAYIT_AGENT_SOCKET', '/run/playit/playitd.sock'),
];
