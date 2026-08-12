<?php

namespace Pelicaninstaller\Playit\Filament\Server\Pages;

use Filament\Facades\Filament;
use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class Playit extends Page
{
    protected static string $view = 'playit::filament.server.pages.playit';

    protected static ?int $navigationSort = 5;

    public function getAddressRows(): array
    {
        $server = Filament::getTenant();
        $map = $this->readJson(config('playit.tunnels_file'));
        $status = $this->readJson(config('playit.status_file'));

        $rows = [];
        foreach ($server->allocations as $allocation) {
            $port = (int) $allocation->port;
            $rows[] = [
                'port' => $allocation->port,
                'playit_address' => $map[(string) $allocation->port] ?? null,
                'cf_hostname' => $this->isCfPort($port) ? "app-$port." . $this->domain() : null,
            ];
        }

        return [
            'rows' => $rows,
            'has_premium' => $status['has_premium'] ?? null,
            'domain' => $this->domain(),
        ];
    }

    protected function domain(): string
    {
        $config = File::exists('/etc/pelican-installer/installer.conf')
            ? file_get_contents('/etc/pelican-installer/installer.conf')
            : '';

        preg_match('/^DOMAIN=(.+)$/m', $config, $m);

        return $m[1] ?? config('app.url');
    }

    protected function isCfPort(int $port): bool
    {
        return in_array($port, [80, 443, 2052, 2053, 2082, 2083, 2086, 2087, 2095, 2096, 8080, 8443], true);
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
