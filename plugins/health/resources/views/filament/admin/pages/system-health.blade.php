<x-filament-panels::page>
    @php($d = $this->getData())

    <x-filament::section>
        <x-slot name="heading">Host Watchdog</x-slot>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div>
                <p class="text-sm text-gray-500 dark:text-gray-400">Last heal run</p>
                <p class="font-semibold">{{ $d['last_heal'] ?? 'never' }}</p>
            </div>
            <div>
                <p class="text-sm text-gray-500 dark:text-gray-400">Disk usage</p>
                <p class="font-semibold">{{ $d['disk_used'] ?? '?' }}%</p>
            </div>
            <div>
                <p class="text-sm text-gray-500 dark:text-gray-400">Routing</p>
                <p class="font-semibold">
                    {{ $d['domain'] ?? '?' }}
                    @if($d['cf_app_routing']) (CF apps on) @endif
                    @if($d['playit_premium']) · playit premium @else · playit free @endif
                </p>
            </div>
        </div>
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">Services</x-slot>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
            @foreach($d['services'] as $name => $state)
                <div class="rounded-lg border px-3 py-2
                    @if($state === 'active') border-success-500/30 bg-success-500/5
                    @else border-danger-500/30 bg-danger-500/5 @endif">
                    <p class="text-sm font-medium">{{ $name }}</p>
                    <p class="text-xs @if($state === 'active') text-success-600 dark:text-success-400 @else text-danger-600 dark:text-danger-400 @endif">
                        {{ $state }}
                    </p>
                </div>
            @endforeach
        </div>
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">Server jars (auto-repaired by the watchdog)</x-slot>
        @if(empty($d['jars']))
            <p class="text-sm text-gray-500 dark:text-gray-400">No servers reported yet.</p>
        @else
            <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                @foreach($d['jars'] as $uuid => $j)
                    <div class="rounded-lg border px-3 py-2 @if($j['jar_ok'] ?? false) border-success-500/30 @else border-danger-500/30 @endif">
                        <p class="text-sm font-medium">{{ $uuid }}</p>
                        <p class="text-xs text-gray-500 dark:text-gray-400">
                            {{ $j['jarfile'] ?? '?' }} · {{ number_format(($j['size'] ?? 0) / 1024 / 1024, 1) }} MB
                            @if($j['fixed'] ?? false) · <span class="text-success-600">repaired</span> @endif
                        </p>
                    </div>
                @endforeach
            </div>
        @endif
    </x-filament::section>
</x-filament-panels::page>
