<?php

namespace Pelicaninstaller\Playit\Filament\Server\Pages;

use Filament\Facades\Filament;
use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class Playit extends Page
{
    protected static string $view = 'playit::filament.server.pages.playit';

    protected static $navigationIcon = 'tabler-world';

    protected static ?int $navigationSort = 5;

    public function getAddressRows(): array
    {
        $server = Filament::getTenant();
        $map = $this->tunnelMap();

        $rows = [];
        foreach ($server->allocations as $allocation) {
            $rows[] = [
                'port' => $allocation->port,
                'address' => $map[(string) $allocation->port] ?? null,
            ];
        }

        return $rows;
    }

    protected function tunnelMap(): array
    {
        $file = config('playit.tunnels_file');
        if (!File::exists($file)) {
            return [];
        }

        $map = json_decode(File::get($file), true);

        return is_array($map) ? $map : [];
    }
}
