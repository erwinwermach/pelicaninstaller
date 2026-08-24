<?php

namespace Pelicaninstaller\Perfctl;

use Filament\Contracts\Plugin;
use Filament\Panel;

class PerfctlPlugin implements Plugin
{
    public function getId(): string
    {
        return 'perfctl';
    }

    public function register(Panel $panel): void
    {
        if ($panel->getId() === 'server') {
            $panel->discoverPages(
                plugin_path('perfctl', 'src/Filament/Server/Pages'),
                'Pelicaninstaller\\Perfctl\\Filament\\Server\\Pages',
            );
        }
    }

    public function boot(Panel $panel): void
    {
    }
}
