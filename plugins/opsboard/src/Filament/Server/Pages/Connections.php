<?php

namespace Pelicaninstaller\OpsBoard\Filament\Server\Pages;

use Filament\Facades\Filament;
use Filament\Pages\Page;
use Pelicaninstaller\OpsBoard\Support\ReadsJson;

class Connections extends Page
{
    use ReadsJson;

    protected string $view = 'opsboard::filament.server.pages.connections';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-plug-connected';

    protected static ?string $navigationLabel = 'Connections';

    protected static ?int $navigationSort = 5;

    public function getData(): array
    {
        $server = Filament::getTenant();
        $routes = $this->readJson(storage_path('app/routes.json'));

        $rows = [];
        foreach ($server?->allocations ?? [] as $allocation) {
            $port = (string) $allocation->port;
            $entries = $routes['ports'][$port] ?? [];

            if (!empty($routes['cf_app'])) {
                foreach ($routes['cf_app'] as $host) {
                    if (str_ends_with($host, '-' . $allocation->port . '.' . ($routes['domain'] ?? ''))) {
                        $entries[] = [
                            'backend' => 'cf',
                            'address' => $host,
                            'note' => 'HTTP apps through Cloudflare tunnel (web servers, bots)',
                        ];
                    }
                }
            }

            $rows[] = [
                'port' => $allocation->port,
                'primary' => $allocation->ip . ':' . $allocation->port,
                'entries' => $entries,
            ];
        }

        return [
            'domain' => $routes['domain'] ?? null,
            'backends' => $routes['backends'] ?? [],
            'rows' => $rows,
        ];
    }
}
