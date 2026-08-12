# Pelican Plugins (research + development)

This directory is for Pelican panel plugins we develop ourselves.
Pelican's plugin system is in beta but fully usable: plugins add pages,
widgets, settings, routes and more without touching panel core files.

## How Pelican plugins work (research summary)

### Structure

```
plugins/<plugin-id>/
├── plugin.json            # metadata + discovery
├── src/                   # plugin code (app/ folder equivalent)
│   ├── <PluginClass>.php  # main class: implements Filament\Contracts\Plugin
│   └── ...                # models, providers, pages, resources...
├── config/<id>.php        # config with env() values
├── lang/                  # translations (namespaced: <id>::key)
├── resources/views/       # blade views (namespaced: <id>::view)
└── database/              # migrations + Seeder/<Name>Seeder.php
```

### plugin.json (required fields)

```json
{
  "id": "my-plugin",          // MUST match the plugin folder name
  "name": "My Plugin",
  "author": "you",
  "version": "1.0.0",
  "description": "...",
  "category": "plugin",       // plugin | theme | language
  "namespace": "Vendor\\MyPlugin",
  "class": "MyPlugin",        // main class in src/
  "panels": ["admin", "app", "server"],  // optional, default: all
  "panel_version": "^1.0.0",  // optional compatibility constraint
  "update_url": "https://..." // optional auto-update json
}
```

The main class implements `Filament\Contracts\Plugin`:

```php
namespace Vendor\MyPlugin;

use Filament\Contracts\Plugin;
use Filament\Panel;

class MyPlugin implements Plugin
{
    public function getId(): string { return 'my-plugin'; }
    public function register(Panel $panel): void { /* register pages/widgets */ }
    public function boot(Panel $panel): void { /* runs per request */ }
}
```

`php artisan p:plugin:make` scaffolds this (stub is in the panel repo).

### Installing / updating

- Import: Admin -> Plugins -> "Import from file" (zip) or import-from-URL,
  or drop the folder into `/var/www/pelican/plugins/` and run
  `php artisan p:plugin:install <id>`.
- Background jobs (migrations, asset builds) require the **queue worker**
  (`pelican-queue.service` - already installed by our installer).
- `p:plugin:list`, `p:plugin:update`, `p:plugin:uninstall`, `p:plugin:enable/disable`.
- API: `POST /api/application/plugins/import/url`, `POST /api/application/plugins/{id}/install`.

### Settings page

Implement `App\Contracts\Plugins\HasPluginSettings`:
`getSettingsForm()`, `getSettingsFormData()`, `saveSettings(array $data)`.
Use `EnvironmentWriterTrait` to persist values into `.env`
(prefix env vars with the plugin id, e.g. `PLAYIT_API_KEY`).

### Panel integration points

- Register Filament resources/pages/widgets via `$panel->discoverPages/Resources/Widgets`
  in `register()`.
- Server panel tenant pages: `app/Filament/Server/Pages/...` equivalents can be
  registered per panel id `server`.
- Modify existing pages: static `registerCustom*` methods
  (e.g. `Console::registerCustomWidgets(ConsoleWidgetPosition::AboveConsole, [...])`).

### Marketplace

https://hub.pelican.dev/plugins (58 plugins, install via panel or zip).

## Plugin ideas / roadmap

- **playit** (in progress, see `playit/`): show each game server's playit.gg
  address in the server panel + one-click "new playit tunnel" for an allocation.
- egg-images sync, player-counter, modpack shortcuts, etc.

## Our install flow

- Fresh installs: the installer imports/installs plugins automatically via the
  panel application API (see `lib/plugins.sh` in the repo root).
- For self-developed plugins: build the zip, host it, add the download URL to
  `lib/plugins.sh`'s `PLUGIN_LIST`, and the installer (or a heal run) will
  import + install it on existing panels too (the plugins phase runs on the
  next `installer.sh` invocation because it is stage-tracked).
