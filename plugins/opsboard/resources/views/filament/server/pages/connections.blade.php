<x-filament-panels::page>
    @php($d = $this->getData())
    @php($backendLabels = ['playit' => 'playit.gg', 'bore' => 'bore relay', 'frp' => 'frp (VPS)', 'direct' => 'direct', 'cf' => 'Cloudflare HTTP'])

    <x-filament::section>
        <x-slot name="heading">How players join this server</x-slot>
        <x-slot name="description">
            Addresses are maintained by the host watchdog. Copy the address for the game port you assigned.
        </x-slot>

        @if(empty($d['rows']))
            <p class="text-sm text-gray-500 dark:text-gray-400">
                This server has no allocations yet — add one on the network page first.
            </p>
        @else
            @foreach($d['rows'] as $row)
                <div class="mb-4 rounded-lg border border-gray-200 p-3 last:mb-0 dark:border-white/10">
                    <div class="flex items-center justify-between">
                        <p class="text-sm font-semibold">Port {{ $row['port'] }}</p>
                        @if(empty($row['entries']))
                            <x-filament::badge color="warning">no public address yet</x-filament::badge>
                        @endif
                    </div>
                    @forelse($row['entries'] as $e)
                        <div x-data="{ copied: false }" class="mt-2 flex flex-wrap items-center gap-2">
                            <span class="text-lg font-bold text-success-600 dark:text-success-400">{{ $e['address'] }}</span>
                            <x-filament::badge :color="($e['backend'] ?? '') === 'cf' ? 'primary' : 'gray'">
                                {{ $backendLabels[$e['backend']] ?? ($e['backend'] ?? '') }}
                            </x-filament::badge>
                            <x-filament::button
                                color="gray"
                                size="xs"
                                icon="tabler-copy"
                                x-on:click="navigator.clipboard.writeText('{{ $e['address'] }}'); copied = true; setTimeout(() => copied = false, 2000)"
                            >
                                <span x-show="!copied">Copy</span>
                                <span x-show="copied" x-cloak>Copied!</span>
                            </x-filament::button>
                            @if(!empty($e['note']))
                                <span class="text-xs text-gray-500 dark:text-gray-400">{{ $e['note'] }}</span>
                            @endif
                        </div>
                    @empty
                        <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">
                            The watchdog creates tunnels automatically and fills this in within a few minutes.
                            If nothing appears, check GAME_ROUTING in /etc/pelican-installer/installer.conf.
                        </p>
                    @endforelse
                </div>
            @endforeach
        @endif
    </x-filament::section>
</x-filament-panels::page>
