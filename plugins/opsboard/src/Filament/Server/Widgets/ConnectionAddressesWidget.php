<?php

namespace Pelicaninstaller\OpsBoard\Filament\Server\Widgets;

use Filament\Facades\Filament;
use Filament\Widgets\Widget;
use Illuminate\Support\Facades\File;

class ConnectionAddressesWidget extends Widget
{
    protected string|int|array $columnSpan = 'full';

    protected string $view = 'opsboard::filament.server.widgets.connection-addresses';

    public function getAddresses(): array
    {
        $server = Filament::getTenant();
        if (!$server) {
            return [];
        }

        $file = storage_path('app/routes.json');
        $routes = File::exists($file) ? json_decode(File::get($file), true) : [];
        if (!is_array($routes)) {
            $routes = [];
        }

        $addresses = [];
        foreach ($server->allocations ?? [] as $allocation) {
            foreach ($routes['ports'][(string) $allocation->port] ?? [] as $entry) {
                if (!empty($entry['address'])) {
                    $addresses[] = [
                        'port' => $allocation->port,
                        'address' => $entry['address'],
                        'backend' => $entry['backend'] ?? '',
                    ];
                }
            }
        }

        return $addresses;
    }
}
