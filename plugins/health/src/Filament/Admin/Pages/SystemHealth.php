<?php

namespace Pelicaninstaller\Health\Filament\Admin\Pages;

use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class SystemHealth extends Page
{
    protected string $view = 'health::filament.admin.pages.system-health';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-heartbeat';

    protected static ?string $navigationGroup = 'System';

    protected static ?int $navigationSort = 1;

    public function getData(): array
    {
        $health = $this->readJson('/var/www/pelican/storage/app/pelican-health.json');
        $jars = $this->readJson('/var/www/pelican/storage/app/pelican-jars.json');
        $public = $this->readJson('/var/www/pelican/storage/app/pelican-public.json');
        $playit = $this->readJson('/var/www/pelican/storage/app/playit-status.json');
        $tunnels = $this->readJson('/var/www/pelican/storage/app/playit-tunnels.json');

        return [
            'last_heal' => $health['last_heal'] ?? null,
            'disk_used' => $health['disk_used'] ?? null,
            'services' => $health['services'] ?? [],
            'jars' => $jars,
            'domain' => $public['domain'] ?? null,
            'cf_app_routing' => ($public['cf_app_routing'] ?? false) === true,
            'playit_premium' => ($playit['has_premium'] ?? false) === true,
            'tunnels' => $tunnels,
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
}
