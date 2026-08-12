<x-filament-panels::page>
    @php($data = $this->getAddressRows())
    @php($rows = $data['rows'])

    @if($data['has_premium'] === true)
        <x-filament::section>
            <p>
                <span class="font-semibold">playit.gg: Premium account</span> — custom TCP/UDP tunnels are
                available (created automatically when an API key is configured).
            </p>
        </x-filament::section>
    @else
        <x-filament::section>
            <p>
                <span class="font-semibold">playit.gg: Free account</span> — game-type tunnels only
                (e.g. Minecraft Java). Custom TCP/UDP requires premium; with an API key configured the
                installer picks the right tunnel type automatically.
            </p>
        </x-filament::section>
    @endif

    @if(empty($rows))
        <x-filament::section>
            <p>No allocations on this server.</p>
        </x-filament::section>
    @else
        @foreach($rows as $row)
            <x-filament::section>
                <x-slot name="heading">
                    Port {{ $row['port'] }} — Routing
                </x-slot>

                <div class="space-y-3">
                    <div>
                        <p class="text-sm text-gray-500 dark:text-gray-400">playit.gg (games / TCP / UDP)</p>
                        @if($row['playit_address'])
                            <p class="text-lg font-semibold text-success-600 dark:text-success-400">
                                {{ $row['playit_address'] }}
                            </p>
                            <p class="text-sm text-gray-500 dark:text-gray-400">
                                Players join this address (shown instead of the raw IP).
                            </p>
                        @else
                            <p class="text-warning-600 dark:text-warning-400">No playit tunnel for this port.</p>
                            @if($data['has_premium'] === true)
                                <x-filament::button
                                    tag="a"
                                    href="https://playit.gg/account/setup/new-tunnel"
                                    target="_blank"
                                    size="sm"
                                    class="mt-2">
                                    Create TCP tunnel on playit.gg (local port {{ $row['port'] }})
                                </x-filament::button>
                            @else
                                <x-filament::button
                                    tag="a"
                                    href="https://playit.gg/account/setup/new-tunnel"
                                    target="_blank"
                                    size="sm"
                                    class="mt-2">
                                    Create Minecraft-Java tunnel on playit.gg (free, local port {{ $row['port'] }})
                                </x-filament::button>
                                <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
                                    Free accounts can only create game-type tunnels (e.g. Minecraft Java).
                                </p>
                            @endif
                            <p class="text-sm text-gray-500 dark:text-gray-400 mt-2">
                                After creating it, the address appears here automatically
                                (sync runs every 10 minutes).
                            </p>
                        @endif
                    </div>

                    <div class="border-t pt-3">
                        <p class="text-sm text-gray-500 dark:text-gray-400">
                            Cloudflare (HTTP apps — Python/JS/Node/Discord bots, web servers)
                        </p>
                        @if($row['cf_supported'])
                            @if($row['cf_active'])
                                <p class="font-semibold text-success-600 dark:text-success-400">
                                    {{ $row['cf_hostname'] }} — active
                                </p>
                                <p class="text-sm text-gray-500 dark:text-gray-400">
                                    Served through the tunnel. HTTP only (Cloudflare forwards HTTP ports only).
                                </p>
                            @else
                                <p class="font-semibold text-gray-500 dark:text-gray-400">
                                    {{ $row['cf_hostname'] }}
                                </p>
                                <p class="text-sm text-gray-500 dark:text-gray-400">
                                    Available for HTTP apps — enable it by setting
                                    <code>CF_APP_ROUTING=yes</code> in
                                    /etc/pelican-installer/installer.conf and re-running
                                    <code>sudo bash /opt/pelican-installer/installer.sh</code>.
                                </p>
                            @endif
                        @else
                            <p class="text-sm text-gray-500 dark:text-gray-400">
                                Not available on port {{ $row['port'] }} — Cloudflare only forwards
                                HTTP ports (80/443/8080/8443/2052-2087/2095-2096) publicly.
                                Game TCP/UDP on this port is served via playit.gg.
                            </p>
                        @endif
                    </div>
                </div>
            </x-filament::section>
        @endforeach
    @endif
</x-filament-panels::page>
