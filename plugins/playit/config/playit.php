<?php

return [
    // playit.gg API key (optional, for automatic address lookup / tunnel creation)
    // https://playit.gg -> Account -> API keys
    'api_key' => env('PLAYIT_API_KEY', ''),

    // The playit agent's local IPC socket (used by the agent CLI)
    'agent_socket' => env('PLAYIT_AGENT_SOCKET', '/run/playit/playitd.sock'),
];
