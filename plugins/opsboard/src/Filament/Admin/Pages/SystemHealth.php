<?php

namespace Pelicaninstaller\OpsBoard\Filament\Admin\Pages;

use Filament\Pages\Page;
use Pelicaninstaller\OpsBoard\Support\ReadsJson;

class SystemHealth extends Page
{
    use ReadsJson;

    protected string $view = 'opsboard::filament.admin.pages.system-health';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-heartbeat';

    protected static ?int $navigationSort = 1;

    public function getData(): array
    {
        return [
            'health' => $this->readJson(storage_path('app/pelican-health.json')),
            'jars' => $this->readJson(storage_path('app/pelican-jars.json')),
            'routes' => $this->readJson(storage_path('app/routes.json')),
        ];
    }
}
