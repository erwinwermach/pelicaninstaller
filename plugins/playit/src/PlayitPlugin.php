<?php

namespace Pelicaninstaller\Playit;

use App\Contracts\Plugins\HasPluginSettings;
use App\Traits\EnvironmentWriterTrait;
use Filament\Contracts\Plugin;
use Filament\Forms\Components\TextInput;
use Filament\Panel;

class PlayitPlugin implements Plugin, HasPluginSettings
{
    use EnvironmentWriterTrait;

    public function getId(): string
    {
        return 'playit';
    }

    public function register(Panel $panel): void
    {
        // Server panel: "Playit" page showing public join addresses for
        // this server's allocations (read from the host-side tunnel map).
        if ($panel->getId() === 'server') {
            $panel->discoverPages(
                plugin_path('playit', 'src/Filament/Server/Pages'),
                'Pelicaninstaller\\Playit\\Filament\\Server\\Pages',
            );
        }
    }

    public function boot(Panel $panel): void
    {
    }

    public function getSettingsFormData(): array
    {
        return [
            'api_key' => config('playit.api_key'),
            'tunnels_file' => config('playit.tunnels_file'),
        ];
    }

    public function getSettingsForm(): array
    {
        return [
            TextInput::make('api_key')
                ->label('playit.gg API key')
                ->helperText('https://playit.gg -> Account -> API keys. Used to look up tunnel addresses.')
                ->password()
                ->revealable(),
            TextInput::make('tunnels_file')
                ->label('Tunnel map file')
                ->default('/etc/pelican-installer/playit-tunnels.json'),
        ];
    }

    public function saveSettings(array $data): void
    {
        $this->writeToEnvironment([
            'PLAYIT_API_KEY' => $data['api_key'] ?? '',
            'PLAYIT_TUNNELS_FILE' => $data['tunnels_file'] ?? '/etc/pelican-installer/playit-tunnels.json',
        ]);
    }
}
