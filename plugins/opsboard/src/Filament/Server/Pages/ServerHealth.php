<?php

namespace Pelicaninstaller\OpsBoard\Filament\Server\Pages;

use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Pelicaninstaller\OpsBoard\Support\ReadsJson;

class ServerHealth extends Page
{
    use ReadsJson;

    protected string $view = 'opsboard::filament.server.pages.server-health';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-heartbeat';

    protected static ?int $navigationSort = 6;

    public function getData(): array
    {
        $uuid = Filament::getTenant()?->uuid;

        return [
            'uuid' => $uuid,
            'jar' => $this->readJson(storage_path('app/pelican-jars.json'))[$uuid] ?? null,
        ];
    }

    protected function getHeaderActions(): array
    {
        return [
            Action::make('repair')
                ->label('Schedule repair')
                ->icon('tabler-tool')
                ->requiresConfirmation()
                ->modalDescription('The host watchdog will check and repair this server\'s files within 5 minutes. Restart the server afterwards.')
                ->action(fn () => $this->scheduleRepair()),
        ];
    }

    public function scheduleRepair(): void
    {
        $server = Filament::getTenant();
        $dir = storage_path('app/requests');
        File::ensureDirectoryExists($dir);
        File::put("$dir/repair-{$server->uuid}.req", now()->toIso8601String());

        Notification::make()
            ->title('Repair scheduled')
            ->body('The host watchdog will fix this server within 5 minutes. Restart it afterwards.')
            ->success()
            ->send();
    }
}
