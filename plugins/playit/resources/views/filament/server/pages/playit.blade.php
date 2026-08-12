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
                        No playit tunnel yet — it is created automatically within a few minutes
                        (the heal system syncs tunnels every 10 minutes).
                    </p>
                @endif
            </x-filament::section>
        @endforeach
    @endif
</x-filament-panels::page>
