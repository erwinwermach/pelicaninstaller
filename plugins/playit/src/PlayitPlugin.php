<?php

namespace Pelicaninstaller\Playit;

use Filament\Contracts\Plugin;
use Filament\Panel;

class PlayitPlugin implements Plugin
{
    public function getId(): string
    {
        return 'playit';
    }

    public function register(Panel $panel): void
    {
        // Register the playit pages/widgets on the server panel:
        //
        // if ($panel->getId() === 'server') {
        //     $panel->discoverPages(
        //         plugin_path('playit', 'src/Filament/Server/Pages'),
        //         'Pelicaninstaller\\Playit\\Filament\\Server\\Pages',
        //     );
        // }
        //
        // Widget idea: a "Playit Address" infolist widget next to the console
        // that queries the playit.gg API (API key from settings) for tunnels
        // matching the server's allocation port and shows the public address.
    }

    public function boot(Panel $panel): void
    {
        // Per-request hooks.
    }
}
