<?php

namespace Pelicaninstaller\Playit\Filament\Server\Pages;

use Filament\Facades\Filament;
use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class Playit extends Page
{
    protected string $view = 'playit::filament.server.pages.playit';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-brand-superhuman';

    public function getAddressRows(): array
    {
        $server = Filament::getTenant();
        $map = $this->readJson(config('playit.tunnels_file', '/var/www/pelican/storage/app/playit-tunnels.json'));
        $status = $this->readJson(config('playit.status_file', '/var/www/pelican/storage/app/playit-status.json'));
        $public = $this->readJson(config('playit.public_state_file', '/var/www/pelican/storage/app/pelican-public.json'));
        $cfEnabled = ($public['cf_app_routing'] ?? false) === true;

        $rows = [];
        foreach ($server->allocations as $allocation) {
            $port = (int) $allocation->port;
            $rows[] = [
                'port' => $allocation->port,
                'playit_address' => $map[(string) $allocation->port] ?? null,
                'cf_hostname' => $this->isCfPort($port) ? "app-$port." . $this->domain() : null,
                'cf_supported' => $this->isCfPort($port),
                'cf_active' => $cfEnabled && $this->isCfPort($port),
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
        $public = $this->readJson(config('playit.public_state_file', '/var/www/pelican/storage/app/pelican-public.json'));
        if (!empty($public['domain'])) {
            return $public['domain'];
        }

        $host = parse_url((string) config('app.url'), PHP_URL_HOST) ?: '';
        $parts = explode('.', $host);

        return count($parts) >= 2 ? implode('.', array_slice($parts, -2)) : $host;
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
