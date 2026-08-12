<?php

namespace Pelicaninstaller\Crashlog\Filament\Admin\Pages;

use Filament\Actions\Action;
use Filament\Pages\Page;
use Pelicaninstaller\Crashlog\Support\ReadsCrashlog;
use Symfony\Component\HttpFoundation\StreamedResponse;

class CrashDashboard extends Page
{
    use ReadsCrashlog;

    protected string $view = 'crashlog::filament.admin.pages.crash-dashboard';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-alert-triangle';

    protected static ?int $navigationSort = 2;

    public string $scopeFilter = 'all';

    public string $levelFilter = 'all';

    public string $detailId = '';

    public function getData(): array
    {
        $audit = $this->readJson('/var/www/pelican/storage/app/crashlog/audit.json')['events'] ?? [];
        $meta = $this->readJson('/var/www/pelican/storage/app/crashlog/meta.json');

        $critical = 0;
        $last24h = 0;
        $affected = [];
        $dayAgo = time() - 86400;
        foreach ($audit as $e) {
            if (($e['level'] ?? '') === 'critical') {
                $critical++;
            }
            if (($e['ts'] ?? 0) > $dayAgo) {
                $last24h++;
            }
            if (!empty($e['server'])) {
                $affected[$e['server']] = true;
            }
        }

        return [
            'audit' => $audit,
            'meta' => $meta,
            'last' => $audit[0] ?? null,
            'stats' => [
                'total' => count($audit),
                'critical' => $critical,
                'last24h' => $last24h,
                'servers' => count($affected),
            ],
        ];
    }

    protected function getHeaderActions(): array
    {
        return [
            Action::make('export_all')
                ->label('Export all (30d)')
                ->icon('tabler-download')
                ->action(fn () => $this->downloadAll()),
        ];
    }

    public function download(string $id): StreamedResponse
    {
        return response()->streamDownload(function () use ($id) {
            echo $this->formatEvent($this->getEventDetail($id));
        }, 'crash-' . basename($id) . '.txt', ['Content-Type' => 'text/plain']);
    }

    public function downloadAll(): StreamedResponse
    {
        return response()->streamDownload(function () {
            $audit = $this->readJson('/var/www/pelican/storage/app/crashlog/audit.json')['events'] ?? [];
            $count = 0;
            foreach (array_slice($audit, 0, 500) as $e) {
                if ($count > 0) {
                    echo "\n\n";
                }
                echo $this->formatEvent($this->getEventDetail($e['id'] ?? ''));
                $count++;
            }
        }, 'crashlog-export-' . date('Y-m-d') . '.txt', ['Content-Type' => 'text/plain']);
    }
}
