<x-filament-panels::page>
    @php($d = $this->getData())
    @php($node = $d['node'] ?? null)

    @if(empty($d['rec']))
        <x-filament::section>
            <x-slot name="heading">No analysis yet</x-slot>
            <p class="text-sm text-gray-500 dark:text-gray-400">
                The host watchdog analyzes every server every 5 minutes and detects the workload type
                (PaperMC, Forge/Fabric, Source engine, Python, Node.js, proxies). This page will show
                a full optimization recommendation once the first analysis ran.
            </p>
        </x-filament::section>
    @else
        @if($node)
            <x-filament::section>
                <x-slot name="heading">Host snapshot</x-slot>
                <div class="flex flex-wrap items-center gap-2">
                    <x-filament::badge color="gray">{{ $node['total_ram_mb'] }} MB host RAM</x-filament::badge>
                    <x-filament::badge color="{{ ($node['available_mb'] ?? 0) < 1024 ? 'danger' : 'success' }}">
                        {{ $node['available_mb'] }} MB available
                    </x-filament::badge>
                    <x-filament::badge color="gray">{{ $node['cores'] }} cores, load {{ $node['load1'] }}</x-filament::badge>
                    <x-filament::badge color="gray">{{ $node['budget_mb'] }} MB tuning budget ({{ $node['infra_reserve_mb'] }} MB reserved for panel/OS)</x-filament::badge>
                    @if(!empty($node['overcommitted']))
                        <x-filament::badge color="danger">memory overcommitted across servers</x-filament::badge>
                    @endif
                </div>
            </x-filament::section>
        @endif

        <x-filament::section>
            <x-slot name="heading">Detected workload: {{ $d['rec']['profile'] }}</x-slot>
            <x-slot name="description">{{ $d['generated'] ? 'Analyzed ' . \Illuminate\Support\Carbon::parse($d['generated'])->diffForHumans() : '' }}</x-slot>

            <div class="flex flex-wrap items-center gap-2">
                <x-filament::badge color="primary" size="lg">{{ $d['rec']['memory_mb'] }} MB allocation</x-filament::badge>
                <x-filament::badge color="gray">container limit: {{ ($d['rec']['effective_limit_mb'] ?? 0) > 0 ? $d['rec']['effective_limit_mb'].' MB' : 'none' }}</x-filament::badge>
                @if(!empty($d['rec']['rss_mb']))
                    <x-filament::badge color="gray">using {{ $d['rec']['rss_mb'] }} MB</x-filament::badge>
                @endif
                @if(!empty($d['rec']['unbounded']))
                    <x-filament::badge color="danger" size="lg">UNBOUNDED HEAP - JVM takes what it wants from the host</x-filament::badge>
                @endif
                @if(($d['rec']['recent_ooms'] ?? 0) > 0)
                    <x-filament::badge color="danger" size="lg">{{ $d['rec']['recent_ooms'] }} recent OOM events</x-filament::badge>
                @endif
                @if(($d['rec']['cant_keep_up_count'] ?? 0) > 0)
                    <x-filament::badge color="warning">{{ $d['rec']['cant_keep_up_count'] }} "Can't keep up" warnings</x-filament::badge>
                @endif
                @if(!empty($d['rec']['network']['slow_link']))
                    <x-filament::badge color="warning">slow link / host pressure detected</x-filament::badge>
                @endif
                @if(!empty($d['rec']['network']['ping_ms']))
                    <x-filament::badge color="gray">route ping ~{{ $d['rec']['network']['ping_ms'] }} ms</x-filament::badge>
                @endif
                @if(!empty($d['applied']))
                    <x-filament::badge color="warning" size="lg">tuning applied ({{ $d['applied']['profile'] }})</x-filament::badge>
                @endif
            </div>

            <p class="mt-3 text-sm text-gray-500 dark:text-gray-400">{{ $d['rec']['reason'] }}</p>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">{{ $d['rec']['mem_note'] ?? '' }}</p>
        </x-filament::section>

        @if(!empty($d['result']))
            <x-filament::section>
                <x-slot name="heading">Last request result</x-slot>
                @if(($d['result']['ok'] ?? false) === true)
                    <div class="flex flex-wrap items-center gap-2">
                        <x-filament::badge color="success">{{ $d['result']['action'] ?? 'done' }}</x-filament::badge>
                        @if(!empty($d['result']['memory_mb']))
                            <x-filament::badge color="gray">memory set to {{ $d['result']['memory_mb'] }} MB</x-filament::badge>
                        @endif
                        @foreach(($d['result']['files'] ?? []) as $f)
                            <x-filament::badge color="gray">{{ $f }} updated</x-filament::badge>
                        @endforeach
                    </div>
                    <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">Restart this server to activate the changes.</p>
                @elseif(isset($d['result']['ok']))
                    <x-filament::badge color="danger">{{ $d['result']['error'] ?? 'failed' }}</x-filament::badge>
                @endif
            </x-filament::section>
        @endif


        @php($props = $d['rec']['file_recs']['server.properties'] ?? [])
        @if(!empty($props))
            <x-filament::section>
                <x-slot name="heading">server.properties recommendations</x-slot>
                <table class="w-full text-left text-sm">
                    <thead><tr class="text-gray-500 dark:text-gray-400">
                        <th class="py-1 pr-3 font-medium">Setting</th>
                        <th class="py-1 pr-3 font-medium">Current</th>
                        <th class="py-1 pr-3 font-medium">Recommended</th>
                        <th class="py-1 font-medium">Why</th>
                    </tr></thead>
                    <tbody>
                    @foreach($props as $key => $p)
                        <tr class="border-t border-gray-200 dark:border-gray-700">
                            <td class="py-1 pr-3 font-mono text-xs">{{ $key }}</td>
                            <td class="py-1 pr-3 font-mono text-xs">{{ $p['current'] }}</td>
                            <td class="py-1 pr-3 font-mono text-xs">{{ $p['recommended'] }}</td>
                            <td class="py-1 text-xs text-gray-500 dark:text-gray-400">{{ $p['reason'] }}</td>
                        </tr>
                    @endforeach
                    </tbody>
                </table>
            </x-filament::section>
        @endif

        @php($jvm = $d['rec']['file_recs']['user_jvm_args'] ?? [])
        @if(!empty($jvm) && !empty($jvm['recommended']))
            <x-filament::section>
                <x-slot name="heading">JVM args file (user_jvm_args.txt)</x-slot>
                <p class="text-sm text-gray-500 dark:text-gray-400">
                    @if(!empty($jvm['current']))
                        Current: <span class="font-mono text-xs">{{ $jvm['current'] }}</span> —
                    @else
                        No heap flags set in the file —
                    @endif
                    recommended: <span class="font-mono text-xs">{{ $jvm['recommended'] }}</span>
                </p>
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
            <x-slot name="heading">Apply optimization bundle</x-slot>
            <x-slot name="description">
                Nothing is changed automatically. Applying updates the startup command, the memory
                allocation (with a matching container limit on next restart) and the recommended config
                files. Originals are backed up and one click restores everything. Restart afterwards.
            </x-slot>
            <div class="flex flex-wrap items-center gap-3">
                @if(!empty($d['applied']))
                    <x-filament::button
                        color="danger"
                        icon="tabler-arrow-back-up"
                        wire:click="revert()"
                        wire:confirm="Restore the original startup, memory and config files? You need to restart the server afterwards."
                    >
                        Revert to original
                    </x-filament::button>
                @else
                    <x-filament::button
                        color="primary"
                        icon="tabler-player-play"
                        wire:click="apply()"
                        wire:confirm="Apply the recommended '{{ $d['rec']['profile'] }}' optimization bundle? Startup, memory and config files change; restart the server afterwards. Revert is available any time."
                    >
                        Apply recommended optimizations
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
