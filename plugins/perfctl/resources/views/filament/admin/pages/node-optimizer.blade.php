<x-filament-panels::page>
    @php($d = $this->getData())
    @php($node = $d['node'] ?? null)

    @if(empty($node))
        <x-filament::section>
            <x-slot name="heading">No host analysis yet</x-slot>
            <p class="text-sm text-gray-500 dark:text-gray-400">
                The host watchdog (heal) analyzes the node and every server every 5 minutes.
                This page will fill in after the first analysis ran.
            </p>
        </x-filament::section>
    @else
        <x-filament::section>
            <x-slot name="heading">Node memory budget</x-slot>
            <div class="flex flex-wrap items-center gap-2">
                <x-filament::badge color="gray" size="lg">{{ $node['total_ram_mb'] }} MB total</x-filament::badge>
                <x-filament::badge color="{{ ($node['available_mb'] ?? 0) < 1024 ? 'danger' : 'success' }}" size="lg">
                    {{ $node['available_mb'] }} MB available
                </x-filament::badge>
                <x-filament::badge color="gray" size="lg">{{ $node['cores'] }} cores</x-filament::badge>
                <x-filament::badge color="gray" size="lg">load {{ $node['load1'] }} / {{ $node['load5'] }} / {{ $node['load15'] }}</x-filament::badge>
            </div>
            <div class="mt-3 space-y-1 text-sm text-gray-500 dark:text-gray-400">
                <p>{{ $node['infra_reserve_mb'] }} MB reserved for OS + panel stack (PHP-FPM, MariaDB, Redis, nginx, Docker).</p>
                <p><span class="font-semibold text-gray-700 dark:text-gray-300">{{ $node['budget_mb'] }} MB</span>
                    is the safe tuning budget for game servers.</p>
                <p>Servers: {{ $node['server_count'] }} — allocated {{ $node['sum_allocated_mb'] }} MB,
                    recommended total {{ $node['sum_recommended_mb'] }} MB.</p>
            </div>
            @if(!empty($node['overcommitted']))
                <p class="mt-2 text-sm text-danger">The recommended memory totals exceed the host budget - lower the per-server allocations or add more RAM.</p>
            @endif
        </x-filament::section>

        @php($servers = $d['servers'] ?? [])
        @if(!empty($servers))
            <x-filament::section>
                <x-slot name="heading">Per-server memory view</x-slot>
                <table class="w-full text-left text-sm">
                    <thead><tr class="text-gray-500 dark:text-gray-400">
                        <th class="py-1 pr-3 font-medium">Server</th>
                        <th class="py-1 pr-3 font-medium">Profile</th>
                        <th class="py-1 pr-3 font-medium">Panel alloc</th>
                        <th class="py-1 pr-3 font-medium">Container limit</th>
                        <th class="py-1 pr-3 font-medium">In use</th>
                        <th class="py-1 font-medium">Recommended</th>
                    </tr></thead>
                    <tbody>
                    @foreach($servers as $s)
                        <tr class="border-t border-gray-200 dark:border-gray-700">
                            <td class="py-1 pr-3">{{ $s['name'] }}</td>
                            <td class="py-1 pr-3 font-mono text-xs">{{ $s['profile'] }}</td>
                            <td class="py-1 pr-3">{{ $s['memory_mb'] }} MB</td>
                            <td class="py-1 pr-3">
                                @if(($s['effective_limit_mb'] ?? 0) > 0)
                                    {{ $s['effective_limit_mb'] }} MB
                                @else
                                    <span class="text-danger">unbounded</span>
                                @endif
                            </td>
                            <td class="py-1 pr-3">{{ $s['rss_mb'] ?? 0 }} MB</td>
                            <td class="py-1">
                                {{ $s['recommended_memory_mb'] }} MB
                                @if(!empty($s['unbounded']))
                                    <span class="text-danger">(fix unbounded heap)</span>
                                @endif
                            </td>
                        </tr>
                    @endforeach
                    </tbody>
                </table>
                <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">
                    Per-server optimization bundles (startup, memory, config files) are on each server's Performance page.
                </p>
            </x-filament::section>
        @endif
    @endif
</x-filament-panels::page>