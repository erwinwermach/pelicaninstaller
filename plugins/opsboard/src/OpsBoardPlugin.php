<?php

namespace Pelicaninstaller\OpsBoard;

use App\Enums\ConsoleWidgetPosition;
use App\Filament\Server\Pages\Console;
use Filament\Contracts\Plugin;
use Filament\Panel;
use Pelicaninstaller\OpsBoard\Filament\Server\Widgets\ConnectionAddressesWidget;

class OpsBoardPlugin implements Plugin
{
    public function getId(): string
    {
        return 'opsboard';
    }

    public function register(Panel $panel): void
    {
        if ($panel->getId() === 'admin') {
            $panel->discoverPages(
                plugin_path('opsboard', 'src/Filament/Admin/Pages'),
                'Pelicaninstaller\\OpsBoard\\Filament\\Admin\\Pages',
            );
        }

        if ($panel->getId() === 'server') {
            $panel->discoverPages(
                plugin_path('opsboard', 'src/Filament/Server/Pages'),
                'Pelicaninstaller\\OpsBoard\\Filament\\Server\\Pages',
            );
            Console::registerCustomWidgets(ConsoleWidgetPosition::AboveConsole, [ConnectionAddressesWidget::class]);
        }
    }

    public function boot(Panel $panel): void
    {
    }
}
