<x-filament-panels::page>
    @php($d = $this->getData())

    <x-filament::section>
        <x-slot name="heading">Server jar</x-slot>
        <x-slot name="description">The watchdog checks and repairs server jars every 5 minutes.</x-slot>
        @if($d['jar'])
            @if($d['jar']['jar_ok'] ?? false)
                <div class="flex items-center gap-2">
                    <x-filament::badge color="success">Healthy</x-filament::badge>
                    @if($d['jar']['fixed'] ?? false)
                        <x-filament::badge color="primary">was repaired automatically</x-filament::badge>
                    @endif
                </div>
                <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">
                    {{ $d['jar']['jarfile'] ?? '?' }} · {{ number_format(($d['jar']['size'] ?? 0) / 1024 / 1024, 1) }} MB
                </p>
            @else
                <div class="flex items-center gap-2">
                    <x-filament::badge color="danger">Broken or missing</x-filament::badge>
                    @if($d['jar']['fixed'] ?? false)
                        <x-filament::badge color="warning">repair was scheduled</x-filament::badge>
                    @endif
                </div>
                <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">
                    Use "Schedule repair" above — the watchdog fixes the startup jar within 5 minutes. Restart the server afterwards.
                </p>
            @endif
        @else
            <p class="text-sm text-gray-500 dark:text-gray-400">
                No report yet — the watchdog has not processed this server (runs every 5 minutes).
            </p>
        @endif
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">What the watchdog fixes automatically</x-slot>
        <ul class="list-inside list-disc space-y-1 text-sm text-gray-500 dark:text-gray-400">
            <li>Missing or broken server jars (vanilla download, Fabric installer)</li>
            <li>Fabric launcher layouts (launch stub vs game jar links)</li>
            <li>Unreadable files after modpack extraction</li>
        </ul>
    </x-filament::section>
</x-filament-panels::page>
