<?php

namespace Pelicaninstaller\OpsBoard\Filament\Server\Pages;

use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Pelicaninstaller\OpsBoard\Support\ReadsJson;
use Symfony\Component\HttpFoundation\StreamedResponse;

class ServerCrashes extends Page
{
    use ReadsJson;

    protected string $view = 'opsboard::filament.server.pages.server-crashes';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-alert-triangle';

    protected static ?string $navigationLabel = 'Crashlogs';

    protected static ?int $navigationSort = 7;

    public const int PAGE_SIZE = 50;

    public string $levelFilter = 'all';

    public int $page = 1;

    public string $detailId = '';

    public string $uploadedUrl = '';

    public function updatedLevelFilter(): void
    {
        $this->page = 1;
    }

    public function getData(): array
    {
        $uuid = Filament::getTenant()?->uuid;
        $events = $this->readJson(storage_path('app/crashlog/index-server-' . $uuid . '.json'))['events'] ?? [];

        $critical = 0;
        $recentCritical = 0;
        $last = null;
        $hourAgo = time() - 3600;
        foreach ($events as $e) {
            if (($e['level'] ?? '') === 'critical') {
                $critical++;
                if (($e['ts'] ?? 0) > $hourAgo) {
                    $recentCritical++;
                }
            }
            if ($last === null || ($e['ts'] ?? 0) > ($last['ts'] ?? 0)) {
                $last = $e;
            }
        }

        $filtered = array_values(array_filter($events, function ($e) {
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
        $paged = array_slice($filtered, ($this->page - 1) * self::PAGE_SIZE, self::PAGE_SIZE);

        return [
            'uuid' => $uuid,
            'events' => $paged,
            'matched' => count($filtered),
            'page' => $this->page,
            'page_count' => $totalPages,
            'critical' => $critical,
            'recent_critical' => $recentCritical,
            'loop_risk' => $recentCritical >= 3,
            'last' => $last,
        ];
    }

    protected function getHeaderActions(): array
    {
        return [
            Action::make('export_all')
                ->label('Export all')
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
        $data = $this->getData();

        return response()->streamDownload(function () use ($data) {
            $count = 0;
            foreach ($data['events'] as $e) {
                if ($count > 0) {
                    echo "\n\n";
                }
                echo $this->formatEvent($this->getEventDetail($e['id'] ?? ''));
                $count++;
            }
        }, 'crashlog-' . $data['uuid'] . '-' . date('Y-m-d') . '.txt', ['Content-Type' => 'text/plain']);
    }
}
