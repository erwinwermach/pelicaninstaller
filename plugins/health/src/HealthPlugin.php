<?php

namespace Pelicaninstaller\Health;

use Filament\Contracts\Plugin;
use Filament\Panel;

class HealthPlugin implements Plugin
{
    public function getId(): string
    {
        return 'health';
    }

    public function register(Panel $panel): void
    {
        if ($panel->getId() === 'admin') {
            $panel->discoverPages(
                plugin_path('health', 'src/Filament/Admin/Pages'),
                'Pelicaninstaller\\Health\\Filament\\Admin\\Pages',
            );
        }

        if ($panel->getId() === 'server') {
            $panel->discoverPages(
                plugin_path('health', 'src/Filament/Server/Pages'),
                'Pelicaninstaller\\Health\\Filament\\Server\\Pages',
            );
        }
    }

    public function boot(Panel $panel): void
    {
    }
}
