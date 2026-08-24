<?php

namespace Pelicaninstaller\OpsBoard\Filament\Admin\Pages;

use Filament\Pages\Page;
use Pelicaninstaller\OpsBoard\Support\ReadsJson;

class RoutingOverview extends Page
{
    use ReadsJson;

    protected string $view = 'opsboard::filament.admin.pages.routing-overview';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-topology-star-ring-3';

    protected static ?string $navigationLabel = 'Routing';

    protected static ?int $navigationSort = 3;

    public function getData(): array
    {
        $routes = $this->readJson(storage_path('app/routes.json'));
        $health = $this->readJson(storage_path('app/pelican-health.json'));

        return [
            'routes' => $routes,
            'backend' => $health['game_routing'] ?? null,
            'services' => $health['services'] ?? [],
        ];
    }
}
