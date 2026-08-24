<x-filament-panels::page>
    @php($d = $this->getData())
    @php($h = $d['health'])

    <x-filament::section>
        <x-slot name="heading">Host Watchdog</x-slot>
        <x-slot name="description">
            Runs every 5 minutes: services, tunnel, DNS, certificates and server files.
        </x-slot>
        <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
            <div>
                <p class="text-sm text-gray-500 dark:text-gray-400">{{ __('Last heal run') }}</p>
                <p class="font-semibold">{{ $h['last_heal'] ?? __('never') }}</p>
            </div>
            <div>
                <p class="text-sm text-gray-500 dark:text-gray-400">{{ __('Disk usage') }}</p>
                <p class="font-semibold">
                    {{ $h['disk_used'] ?? '?' }}%
                    @if(($h['disk_used'] ?? 0) >= 90)
                        <x-filament::badge color="danger" class="align-middle">full</x-filament::badge>
                    @elseif(($h['disk_used'] ?? 0) >= 75)
                        <x-filament::badge color="warning" class="align-middle">high</x-filament::badge>
                    @endif
                </p>
            </div>
            <div>
                <p class="text-sm text-gray-500 dark:text-gray-400">{{ __('Game routing') }}</p>
                <p class="font-semibold">
                    {{ $h['game_routing'] ?? '?' }}
                    @if(!empty($d['routes']['domain']))
                        · {{ $d['routes']['domain'] }}
                    @endif
                </p>
            </div>
        </div>
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">Services</x-slot>
        <div class="grid grid-cols-2 gap-2 md:grid-cols-4">
            @foreach($h['services'] ?? [] as $name => $state)
                <div class="flex items-center justify-between rounded-lg border border-gray-200 px-3 py-2 dark:border-white/10">
                    <span class="text-sm font-medium">{{ $name }}</span>
                    <x-filament::badge :color="$state === 'active' ? 'success' : 'danger'">
                        {{ $state }}
                    </x-filament::badge>
                </div>
            @endforeach
        </div>
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">Server jars</x-slot>
        <x-slot name="description">Auto-repaired by the watchdog when broken or missing.</x-slot>
        @if(empty($d['jars']))
            <p class="text-sm text-gray-500 dark:text-gray-400">No servers reported yet.</p>
        @else
            <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
                @foreach($d['jars'] as $uuid => $j)
                    <div class="rounded-lg border border-gray-200 px-3 py-2 dark:border-white/10">
                        <div class="flex items-center justify-between gap-2">
                            <span class="truncate font-mono text-xs text-gray-500 dark:text-gray-400">{{ $uuid }}</span>
                            <x-filament::badge :color="($j['jar_ok'] ?? false) ? 'success' : 'danger'">
                                {{ ($j['jar_ok'] ?? false) ? 'healthy' : 'broken' }}
                            </x-filament::badge>
                        </div>
                        <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                            {{ $j['jarfile'] ?? '?' }} · {{ number_format(($j['size'] ?? 0) / 1024 / 1024, 1) }} MB
                            @if($j['fixed'] ?? false)
                                · <span class="text-success-600 dark:text-success-400">repaired</span>
                            @endif
                        </p>
                    </div>
                @endforeach
            </div>
        @endif
    </x-filament::section>
</x-filament-panels::page>
