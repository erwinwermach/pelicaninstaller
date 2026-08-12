<?php

namespace Pelicaninstaller\Crashlog\Filament\Server\Pages;

use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Pages\Page;
use Pelicaninstaller\Crashlog\Support\ReadsCrashlog;
use Symfony\Component\HttpFoundation\StreamedResponse;

class ServerCrashes extends Page
{
    use ReadsCrashlog;

    protected string $view = 'crashlog::filament.server.pages.server-crashes';

    protected static \BackedEnum|string|null $navigationIcon = 'tabler-alert-triangle';

    protected static ?int $navigationSort = 7;

    public string $detailId = '';

    public function getData(): array
    {
        $uuid = Filament::getTenant()?->uuid;
        $events = $this->readJson('/var/www/pelican/storage/app/crashlog/index-server-' . $uuid . '.json')['events'] ?? [];

        $critical = 0;
        $last = null;
        foreach ($events as $e) {
            if (($e['level'] ?? '') === 'critical') {
                $critical++;
            }
            if ($last === null || ($e['ts'] ?? 0) > ($last['ts'] ?? 0)) {
                $last = $e;
            }
        }

        return [
            'uuid' => $uuid,
            'events' => $events,
            'critical' => $critical,
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

    public function exportAction(string $id): Action
    {
        return Action::make('export_' . $id)
            ->label('Export')
            ->icon('tabler-download')
            ->color('gray')
            ->action(fn () => $this->downloadEvent($id));
    }

    public function downloadEvent(string $id): StreamedResponse
    {
        return response()->streamDownload(function () use ($id) {
            echo $this->formatEvent($this->getEventDetail($id));
        }, 'crash-' . basename($id) . '.txt', ['Content-Type' => 'text/plain']);
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
