<?php

namespace Pelicaninstaller\Playit\Filament\Server\Pages;

use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Infolists\Components\TextEntry;
use Filament\Infolists\Infolist;
use Filament\Pages\Page;
use Illuminate\Support\Facades\File;

class Playit extends Page
{
    protected static string $view = 'playit::filament.server.pages.playit';

    protected static ?string $navigationIcon = 'tabler-brand-superhuman';

    protected static ?int $navigationSort = 5;

    public function infolist(Infolist $infolist): Infolist
    {
        $server = Filament::getTenant();
        $addresses = $this->addressesForServer($server);

        $entries = [];
        foreach ($server->allocations as $allocation) {
            $address = $addresses[(string) $allocation->port] ?? null;
            $entries[] = TextEntry::make("allocation_{$allocation->id}")
                ->label('Port ' . $allocation->port . ' (allocation)')
                ->state($address ?: 'no playit tunnel yet (auto-syncs every few minutes)')
                ->color($address ? 'success' : 'warning')
                ->copyable($address !== null)
                ->helperText($address
                    ? 'Players join this address.'
                    : 'Run "sudo bash /opt/pelican-installer/installer.sh" or wait for the heal cycle.');
        }

        return $infolist->schema($entries);
    }

    protected function getHeaderActions(): array
    {
        return [
            Action::make('refresh')
                ->label('Refresh')
                ->icon('tabler-refresh')
                ->action(fn () => $this->refresh()),
        ];
    }

    public function refresh(): void
    {
        $this->dispatch('$refresh');
    }

    protected function addressesForServer($server): array
    {
        $file = config('playit.tunnels_file');
        if (!File::exists($file)) {
            return [];
        }

        $map = json_decode(File::get($file), true);
        if (!is_array($map)) {
            return [];
        }

        return $map;
    }
}
