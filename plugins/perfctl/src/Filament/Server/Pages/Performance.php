<?php

namespace Pelicaninstaller\Perfctl\Filament\Server\Pages;

use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class Performance extends Page
{
    protected string $view = 'perfctl::filament.server.pages.performance';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-gauge';

    protected static ?string $navigationLabel = 'Performance';

    protected static ?int $navigationSort = 8;

    public static array $profiles = [
        'mc-paper' => 'PaperMC / Purpur / Pufferfish - G1 tuned for low pause times',
        'mc-fabric' => 'Fabric modded - G1 with larger regions for big heaps',
        'mc-forge' => 'Forge / NeoForge modded - G1 for heavy mod workloads',
        'mc-generic' => 'Vanilla & other Java Minecraft - balanced Aikar-style set',
        'proxy-java' => 'Velocity / Waterfall / BungeeCord - small steady heap',
        'source-engine' => 'Source engine (CS, GMod, TF2) - stable srcds arguments',
        'python' => 'Python bots and apps - unbuffered output, no bytecode files',
        'nodejs' => 'Node.js apps - heap capped to the allocation size',
    ];

    public function getData(): array
    {
        $uuid = Filament::getTenant()?->uuid;

        $recs = $this->readJson(storage_path('app/perf-recommendations.json'));
        $rec = $recs['servers'][$uuid] ?? null;
        $applied = $this->readJson(storage_path('app/perf-applied-public.json'))[$uuid] ?? null;
        $result = $this->readJson(storage_path('app/requests/perf-' . $uuid . '.result'));

        return [
            'uuid' => $uuid,
            'rec' => $rec,
            'applied' => $applied,
            'result' => $result,
            'profiles' => self::$profiles,
            'generated' => $recs['generated'] ?? null,
            'node' => $recs['node'] ?? null,
        ];
    }

    protected function readJson(string $path): array
    {
        if (!File::exists($path)) {
            return [];
        }

        $data = json_decode(File::get($path), true);

        return is_array($data) ? $data : [];
    }

    protected function request(array $payload): void
    {
        $server = Filament::getTenant();
        $dir = storage_path('app/requests');
        File::ensureDirectoryExists($dir);
        File::put("$dir/perf-{$server->uuid}.req", json_encode($payload));
    }

    protected function getHeaderActions(): array
    {
        return [
            Action::make('refresh')
                ->label('Refresh analysis')
                ->icon('tabler-refresh')
                ->action(function () {
                    Notification::make()
                        ->title('Analysis refreshes every 5 minutes')
                        ->body('The watchdog re-analyzes servers automatically. This page shows the latest snapshot.')
                        ->info()
                        ->send();
                }),
        ];
    }

    public function apply(): void
    {
        $d = $this->getData();
        if (empty($d['rec']['profile'])) {
            Notification::make()
                ->title('Nothing to apply')
                ->body('No recommendation available yet - the watchdog analyzes every 5 minutes.')
                ->warning()
                ->send();

            return;
        }

        if (!empty($d['applied'])) {
            Notification::make()
                ->title('Tuning already applied')
                ->body('Revert first if you want to re-apply after changes.')
                ->warning()
                ->send();

            return;
        }

        $this->request(['op' => 'apply', 'profile' => $d['rec']['profile']]);
        Notification::make()
            ->title('Tuning scheduled')
            ->body("The '{$d['rec']['profile']}' optimization bundle (startup flags, memory and config files) will be applied within 5 minutes. Restart this server afterwards. You can revert any time.")
            ->success()
            ->send();
    }

    public function revert(): void
    {
        $this->request(['op' => 'revert']);
        Notification::make()
            ->title('Revert scheduled')
            ->body('The original startup command, memory allocation and config files will be restored within 5 minutes. Restart this server afterwards.')
            ->success()
            ->send();
    }
}
