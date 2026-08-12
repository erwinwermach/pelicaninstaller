<?php

namespace Pelicaninstaller\Crashlog;

use Filament\Contracts\Plugin;
use Filament\Panel;

class CrashlogPlugin implements Plugin
{
    public function getId(): string
    {
        return 'crashlog';
    }

    public function register(Panel $panel): void
    {
        if ($panel->getId() === 'admin') {
            $panel->discoverPages(
                plugin_path('crashlog', 'src/Filament/Admin/Pages'),
                'Pelicaninstaller\\Crashlog\\Filament\\Admin\\Pages',
            );
        }

        if ($panel->getId() === 'server') {
            $panel->discoverPages(
                plugin_path('crashlog', 'src/Filament/Server/Pages'),
                'Pelicaninstaller\\Crashlog\\Filament\\Server\\Pages',
            );
        }
    }

    public function boot(Panel $panel): void
    {
    }
}
