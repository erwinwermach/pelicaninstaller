<x-filament-panels::page>
    @php($d = $this->getData())
    @php($r = $d['routes'])
    @php($backendLabels = ['playit' => 'playit.gg', 'bore' => 'bore (open-source relay)', 'frp' => 'frp via your VPS', 'direct' => 'direct / router forwarding', 'cf' => 'Cloudflare tunnel (HTTP apps)'])

    <x-filament::section>
        <x-slot name="heading">Game routing</x-slot>
        <x-slot name="description">
            How players reach game servers. Configured backend:
            {{ strtoupper($d['backend'] ?? 'unknown') }} — change it via
            <code>GAME_ROUTING</code> in /etc/pelican-installer/installer.conf.
        </x-slot>
        @if(empty($r))
            <p class="text-sm text-gray-500 dark:text-gray-400">
                No routing state yet — the watchdog writes it on its next run.
            </p>
        @else
            <div class="flex flex-wrap gap-2">
                @foreach(($r['backends'] ?? []) as $name => $info)
                    <x-filament::badge :color="($info['active'] ?? false) ? 'success' : 'gray'" size="lg">
                        {{ $backendLabels[$name] ?? $name }}
                    </x-filament::badge>
                @endforeach
                @if(!empty($r['domain']))
                    <x-filament::badge color="primary" size="lg">{{ $r['domain'] }}</x-filament::badge>
                @endif
            </div>
            @if(empty($r['ports']))
                <p class="mt-3 text-sm text-warning-600 dark:text-warning-400">
                    No public game addresses yet. If this host is behind CGNAT, use playit, bore or frp-vps as GAME_ROUTING — direct routing cannot work there.
                </p>
            @endif
        @endif
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">Addresses per port</x-slot>
        @if(empty($r['ports'] ?? []))
            <p class="text-sm text-gray-500 dark:text-gray-400">Nothing to show yet.</p>
        @else
            <div class="overflow-x-auto">
                <table class="w-full text-left text-sm">
                    <thead>
                        <tr class="border-b border-gray-200 dark:border-white/10">
                            <th class="py-2 pr-4 font-medium text-gray-500 dark:text-gray-400">Port</th>
                            <th class="py-2 pr-4 font-medium text-gray-500 dark:text-gray-400">Backend</th>
                            <th class="py-2 pr-4 font-medium text-gray-500 dark:text-gray-400">Player address</th>
                            <th class="py-2 font-medium text-gray-500 dark:text-gray-400">Note</th>
                        </tr>
                    </thead>
                    <tbody>
                        @foreach($r['ports'] as $port => $entries)
                            @foreach($entries as $i => $e)
                                <tr class="border-b border-gray-100 last:border-0 dark:border-white/5">
                                    <td class="py-2 pr-4 font-mono">
                                        @if($i === 0){{ $port }}@endif
                                    </td>
                                    <td class="py-2 pr-4">
                                        <x-filament::badge :color="$e['backend'] === 'cf' ? 'primary' : 'success'">
                                            {{ $backendLabels[$e['backend']] ?? $e['backend'] }}
                                        </x-filament::badge>
                                    </td>
                                    <td class="py-2 pr-4 font-semibold">{{ $e['address'] }}</td>
                                    <td class="py-2 text-gray-500 dark:text-gray-400">{{ $e['note'] ?? '' }}</td>
                                </tr>
                            @endforeach
                        @endforeach
                    </tbody>
                </table>
            </div>
        @endif
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">HTTP apps (Cloudflare)</x-slot>
        @if(!empty($r['cf_app']))
            <ul class="list-inside list-disc space-y-1">
                @foreach($r['cf_app'] as $host)
                    <li><span class="font-mono text-sm">{{ $host }}</span></li>
                @endforeach
            </ul>
            <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">
                Reachable through the tunnel for web apps and bots on supported HTTP ports only.
            </p>
        @else
            <p class="text-sm text-gray-500 dark:text-gray-400">
                Disabled. Enable with <code>CF_APP_ROUTING=yes</code> in
                /etc/pelican-installer/installer.conf, then re-run the installer.
            </p>
        @endif
    </x-filament::section>
</x-filament-panels::page>
