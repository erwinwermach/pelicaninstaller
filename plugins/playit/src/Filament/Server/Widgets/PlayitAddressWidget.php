<?php

namespace Pelicaninstaller\Playit\Filament\Server\Widgets;

use Filament\Facades\Filament;
use Filament\Widgets\Widget;
use Illuminate\Support\Facades\File;

class PlayitAddressWidget extends Widget
{
    protected string|int|array $columnSpan = 'full';

    protected string $view = 'playit::filament.server.widgets.playit-address';

    public function getAddresses(): array
    {
        $server = Filament::getTenant();
        if (!$server) {
            return [];
        }

        $file = config('playit.tunnels_file', '/etc/pelican-installer/playit-tunnels.json');
        $map = File::exists($file) ? json_decode(File::get($file), true) : null;
        if (!is_array($map)) {
            $map = [];
        }

        $addresses = [];
        foreach ($server->allocations as $allocation) {
            $address = $map[(string) $allocation->port] ?? null;
            if ($address) {
                $addresses[] = ['port' => $allocation->port, 'address' => $address];
            }
        }

        return $addresses;
    }
}
