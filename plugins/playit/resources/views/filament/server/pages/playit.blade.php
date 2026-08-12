<x-filament-panels::page>
    @php($rows = $this->getAddressRows())

    @if(empty($rows))
        <x-filament::section>
            <p>No allocations on this server.</p>
        </x-filament::section>
    @else
        @foreach($rows as $row)
            <x-filament::section>
                <x-slot name="heading">
                    Port {{ $row['port'] }} — playit.gg
                </x-slot>

                @if($row['address'])
                    <p class="text-lg font-semibold text-success-600 dark:text-success-400">
                        {{ $row['address'] }}
                    </p>
                    <p class="text-sm text-gray-500 dark:text-gray-400">
                        Players join this address. It is created and kept up to date automatically
                        (playit agent + installer sync).
                    </p>
                @else
                    <p class="text-warning-600 dark:text-warning-400">
                        No playit tunnel for this port yet.
                    </p>
                    <x-filament::button
                        tag="a"
                        href="https://playit.gg/tunnels"
                        target="_blank"
                        size="sm"
                        class="mt-2">
                        Create on playit.gg (TCP, local port {{ $row['port'] }})
                    </x-filament::button>
                    <p class="text-sm text-gray-500 dark:text-gray-400 mt-2">
                        After creating it, the address appears here automatically
                        (sync runs every 10 minutes).
                    </p>
                @endif
            </x-filament::section>
        @endforeach
    @endif
</x-filament-panels::page>
