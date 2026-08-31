<?php

namespace Pelicaninstaller\Perfctl\Filament\Admin\Pages;

use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class NodeOptimizer extends Page
{
    protected string $view = 'perfctl::filament.admin.pages.node-optimizer';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-server-cog';

    protected static ?string $navigationLabel = 'Node optimizer';

    protected static ?int $navigationSort = 9;

    public function getData(): array
    {
        if (!File::exists(storage_path('app/perf-recommendations.json'))) {
            return [];
        }

        $data = json_decode(File::get(storage_path('app/perf-recommendations.json')), true);

        return is_array($data) ? $data : [];
    }
}