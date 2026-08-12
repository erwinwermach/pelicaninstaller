<?php

return [
    // playit.gg API key (https://playit.gg -> Account -> API keys).
    // Used for live address lookup; tunnel creation is done host-side
    // (installer/heal) so the panel only needs read access.
    'api_key' => env('PLAYIT_API_KEY', ''),

    // Files written by the host-side playit enforcer (world-readable for
    // www-data, stored inside the panel's storage dir on purpose - the
    // installer config dir is root-only and the panel cannot read it):
    // tunnels:  {"25565": "xxx.tun.ply.gg", ...}  (port -> public address)
    // status:   {"has_premium": bool, ...}
    // public:   {"domain": "example.com", "cf_app_routing": bool}
    'tunnels_file' => env('PLAYIT_TUNNELS_FILE', '/var/www/pelican/storage/app/playit-tunnels.json'),
    'status_file' => env('PLAYIT_STATUS_FILE', '/var/www/pelican/storage/app/playit-status.json'),
    'public_state_file' => env('PLAYIT_PUBLIC_STATE_FILE', '/var/www/pelican/storage/app/pelican-public.json'),

    // The playit agent's local IPC socket (agent CLI)
    'agent_socket' => env('PLAYIT_AGENT_SOCKET', '/run/playit/playitd.sock'),
];
