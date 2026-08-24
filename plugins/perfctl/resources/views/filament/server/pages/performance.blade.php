<x-filament-panels::page>
    @php($d = $this->getData())

    @if(empty($d['rec']))
        <x-filament::section>
            <x-slot name="heading">No analysis yet</x-slot>
            <p class="text-sm text-gray-500 dark:text-gray-400">
                The host watchdog analyzes every server every 5 minutes and detects the workload type
                (PaperMC, Forge/Fabric, Source engine, Python, Node.js, proxies). This page will show
                a tuned startup recommendation once the first analysis ran.
            </p>
        </x-filament::section>
    @else
        <x-filament::section>
            <x-slot name="heading">Detected workload: {{ $d['rec']['profile'] }}</x-slot>
            <x-slot name="description">{{ $d['generated'] ? 'Analyzed ' . \Illuminate\Support\Carbon::parse($d['generated'])->diffForHumans() : '' }}</x-slot>

            <div class="flex flex-wrap items-center gap-2">
                <x-filament::badge color="primary" size="lg">{{ $d['rec']['memory_mb'] }} MB allocation</x-filament::badge>
                @if(($d['rec']['recent_ooms'] ?? 0) > 0)
                    <x-filament::badge color="danger" size="lg">{{ $d['rec']['recent_ooms'] }} recent OOM events</x-filament::badge>
                @else
                    <x-filament::badge color="success" size="lg">no recent OOM</x-filament::badge>
                @endif
                @if(!empty($d['applied']))
                    <x-filament::badge color="warning" size="lg">tuning applied ({{ $d['applied']['profile'] }})</x-filament::badge>
                @endif
            </div>

            <p class="mt-3 text-sm text-gray-500 dark:text-gray-400">{{ $d['rec']['reason'] }}</p>
        </x-filament::section>

        @if(!empty($d['result']))
            <x-filament::section>
                <x-slot name="heading">Last request result</x-slot>
                @if(($d['result']['ok'] ?? false) === true)
                    <div class="flex items-center gap-2">
                        <x-filament::badge color="success">{{ $d['result']['action'] ?? 'done' }}</x-filament::badge>
                    </div>
                    @if(!empty($d['result']['startup']))
                        <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">Restart this server to activate the new startup command.</p>
                    @endif
                @elseif(isset($d['result']['ok']))
                    <x-filament::badge color="danger">{{ $d['result']['error'] ?? 'failed' }}</x-filament::badge>
                @endif
            </x-filament::section>
        @endif

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <x-filament::section>
                <x-slot name="heading">Current startup command</x-slot>
                <pre class="overflow-x-auto rounded-lg bg-gray-100 p-3 text-xs text-gray-800 dark:bg-gray-900 dark:text-gray-200">{{ $d['rec']['current_startup'] }}</pre>
            </x-filament::section>
            <x-filament::section>
                <x-slot name="heading">Recommended startup command</x-slot>
                <pre class="overflow-x-auto rounded-lg bg-gray-100 p-3 text-xs text-gray-800 dark:bg-gray-900 dark:text-gray-200">{{ $d['rec']['recommended_startup'] }}</pre>
            </x-filament::section>
        </div>

        <x-filament::section>
            <x-slot name="heading">Apply manually</x-slot>
            <x-slot name="description">
                Nothing is changed automatically. Applying replaces this server's startup command;
                the original is backed up and can be restored with one click. Restart the server afterwards.
            </x-slot>
            <div class="flex flex-wrap items-center gap-3">
                @if(!empty($d['applied']))
                    <x-filament::button
                        color="danger"
                        icon="tabler-arrow-back-up"
                        wire:click="revert()"
                        wire:confirm="Restore the original startup command? You need to restart the server afterwards."
                    >
                        Revert to original
                    </x-filament::button>
                @else
                    <x-filament::button
                        color="primary"
                        icon="tabler-player-play"
                        wire:click="apply()"
                        wire:confirm="Apply the recommended '{{ $d['rec']['profile'] }}' flags? This changes the startup command; restart the server afterwards. Revert is available any time."
                    >
                        Apply recommended flags
                    </x-filament::button>
                @endif
            </div>
        </x-filament::section>
    @endif

    <x-filament::section>
        <x-slot name="heading">Available profiles</x-slot>
        <ul class="space-y-1 text-sm text-gray-500 dark:text-gray-400">
            @foreach($d['profiles'] as $id => $desc)
                <li><span class="font-mono font-semibold text-gray-700 dark:text-gray-300">{{ $id }}</span> — {{ $desc }}</li>
            @endforeach
        </ul>
    </x-filament::section>
</x-filament-panels::page>
