<?php

namespace Pelicaninstaller\Health\Filament\Server\Pages;

use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class ServerHealth extends Page
{
    protected string $view = 'health::filament.server.pages.server-health';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-heartbeat';

    protected static ?int $navigationSort = 6;

    public function getData(): array
    {
        $server = Filament::getTenant();
        $uuid = $server?->uuid;

        $jars = $this->readJson('/var/www/pelican/storage/app/pelican-jars.json');
        $tunnels = $this->readJson('/var/www/pelican/storage/app/playit-tunnels.json');
        $public = $this->readJson('/var/www/pelican/storage/app/pelican-public.json');

        $jar = $jars[$uuid] ?? null;

        $addresses = [];
        foreach ($server?->allocations ?? [] as $allocation) {
            $address = $tunnels[(string) $allocation->port] ?? null;
            if ($address) {
                $addresses[] = ['port' => $allocation->port, 'address' => $address];
            }
        }

        return [
            'uuid' => $uuid,
            'jar' => $jar,
            'addresses' => $addresses,
            'domain' => $public['domain'] ?? null,
            'cf_app_routing' => ($public['cf_app_routing'] ?? false) === true,
        ];
    }

    protected function getHeaderActions(): array
    {
        return [
            Action::make('repair')
                ->label('Schedule repair')
                ->icon('tabler-tool')
                ->requiresConfirmation()
                ->action(fn () => $this->scheduleRepair()),
        ];
    }

    public function scheduleRepair(): void
    {
        $server = Filament::getTenant();
        $dir = '/var/www/pelican/storage/app/requests';
        File::makeDirectory($dir, 0755, true, true);
        File::put("$dir/repair-{$server->uuid}.req", now()->toIso8601String());

        Notification::make()
            ->title('Repair scheduled')
            ->body('The host watchdog will fix this server within 5 minutes. Refresh later to see the result.')
            ->success()
            ->send();
    }

    protected function readJson(string $path): array
    {
        if (!File::exists($path)) {
            return [];
        }

        $data = json_decode(File::get($path), true);

        return is_array($data) ? $data : [];
    }
}
