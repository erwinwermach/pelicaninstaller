<?php

namespace Pelicaninstaller\OpsBoard\Filament\Admin\Pages;

use Filament\Actions\Action;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Pelicaninstaller\OpsBoard\Support\ReadsJson;
use Symfony\Component\HttpFoundation\StreamedResponse;

class CrashDashboard extends Page
{
    use ReadsJson;

    protected string $view = 'opsboard::filament.admin.pages.crash-dashboard';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-alert-triangle';

    protected static ?string $navigationLabel = 'Crashlogs';

    protected static ?int $navigationSort = 2;

    public const int PAGE_SIZE = 50;

    public string $scopeFilter = 'all';

    public string $levelFilter = 'all';

    public int $page = 1;

    public string $detailId = '';

    public string $uploadedUrl = '';

    public function updatedScopeFilter(): void
    {
        $this->page = 1;
    }

    public function updatedLevelFilter(): void
    {
        $this->page = 1;
    }

    public function getData(): array
    {
        $audit = $this->readJson(storage_path('app/crashlog/audit.json'))['events'] ?? [];
        $meta = $this->readJson(storage_path('app/crashlog/meta.json'));

        $critical = 0;
        $last24h = 0;
        $affected = [];
        $dayAgo = time() - 86400;
        foreach ($audit as $e) {
            if (($e['level'] ?? '') === 'critical') {
                $critical++;
                if (($e['ts'] ?? 0) > $dayAgo) {
                    $last24h++;
                }
            }
            if (!empty($e['server'])) {
                $affected[$e['server']] = true;
            }
        }

        $filtered = array_values(array_filter($audit, function ($e) {
            if ($this->scopeFilter !== 'all' && ($e['scope'] ?? '') !== $this->scopeFilter) {
                return false;
            }
            $lvl = $e['level'] ?? 'error';
            if ($this->levelFilter === 'all') {
                return true;
            }
            if ($this->levelFilter === 'crash') {
                return $lvl === 'critical';
            }

            return $lvl === $this->levelFilter;
        }));

        $totalPages = max(1, (int) ceil(count($filtered) / self::PAGE_SIZE));
        $this->page = min(max(1, $this->page), $totalPages);
        $events = array_slice($filtered, ($this->page - 1) * self::PAGE_SIZE, self::PAGE_SIZE);

        return [
            'stats' => [
                'total' => count($audit),
                'critical' => $critical,
                'last24h' => $last24h,
                'servers' => count($affected),
            ],
            'meta' => $meta,
            'events' => $events,
            'matched' => count($filtered),
            'page' => $this->page,
            'page_count' => $totalPages,
            'latest_issue' => $audit[0]['issue'] ?? null,
            'latest_meta' => $audit[0] ?? null,
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

    public function upload(string $id): void
    {
        $event = $this->getEventDetail($id);
        if (empty($event)) {
            Notification::make()->title('Event not found')->danger()->send();

            return;
        }

        $url = $this->mclogsPost($this->formatEvent($event));
        if ($url) {
            $this->uploadedUrl = $url;
            Notification::make()
                ->title('Log uploaded to mclo.gs')
                ->body($url)
                ->success()
                ->send();
        } else {
            Notification::make()
                ->title('Upload failed')
                ->body('mclo.gs did not accept the log (too large or unreachable).')
                ->danger()
                ->send();
        }
    }

    public function downloadAll(): StreamedResponse
    {
        return response()->streamDownload(function () {
            $audit = $this->readJson(storage_path('app/crashlog/audit.json'))['events'] ?? [];
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
