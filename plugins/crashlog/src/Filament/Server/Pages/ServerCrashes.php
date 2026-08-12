<?php

namespace Pelicaninstaller\Crashlog\Filament\Server\Pages;

use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Pelicaninstaller\Crashlog\Support\ReadsCrashlog;
use Symfony\Component\HttpFoundation\StreamedResponse;

class ServerCrashes extends Page
{
    use ReadsCrashlog;

    protected string $view = 'crashlog::filament.server.pages.server-crashes';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-alert-triangle';

    protected static ?string $navigationLabel = 'Crashlogs';

    protected static ?int $navigationSort = 7;

    public string $levelFilter = 'all';

    public string $detailId = '';

    public string $uploadedUrl = '';

    public function getData(): array
    {
        $uuid = Filament::getTenant()?->uuid;
        $events = $this->readJson('/var/www/pelican/storage/app/crashlog/index-server-' . $uuid . '.json')['events'] ?? [];

        $critical = 0;
        $recent = 0;
        $last = null;
        $hourAgo = time() - 3600;
        foreach ($events as $e) {
            if (($e['level'] ?? '') === 'critical') {
                $critical++;
                if (($e['ts'] ?? 0) > $hourAgo) {
                    $recent++;
                }
            }
            if ($last === null || ($e['ts'] ?? 0) > ($last['ts'] ?? 0)) {
                $last = $e;
            }
        }

        return [
            'uuid' => $uuid,
            'events' => $events,
            'critical' => $critical,
            'recent_critical' => $recent,
            'loop_risk' => $recent >= 3,
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
            $this->dispatch('copylink', url: $url);
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

    protected function mclogsPost(string $content): ?string
    {
        $payload = http_build_query(['content' => $content]);
        $resp = @file_get_contents('https://api.mclo.gs/1/log', false, stream_context_create([
            'http' => [
                'method' => 'POST',
                'header' => "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: " . strlen($payload),
                'content' => $payload,
                'timeout' => 30,
            ],
        ]));
        if ($resp === false) {
            return null;
        }

        $data = json_decode($resp, true);

        return (!empty($data['success']) && !empty($data['url'])) ? $data['url'] : null;
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
