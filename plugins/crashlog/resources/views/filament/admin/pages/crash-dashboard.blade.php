<x-filament-panels::page>
    @php($d = $this->getData())

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <x-filament::section>
            <x-slot name="heading">Total events</x-slot>
            <p class="text-3xl font-bold">{{ $d['stats']['total'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">last 30 days</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Critical</x-slot>
            <p @class([
                'text-3xl font-bold',
                'text-danger-600 dark:text-danger-400' => $d['stats']['critical'] > 0,
            ])>{{ $d['stats']['critical'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">crashes / OOM / segfaults</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Last 24 hours</x-slot>
            <p class="text-3xl font-bold">{{ $d['stats']['last24h'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">new events</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Affected servers</x-slot>
            <p class="text-3xl font-bold">{{ $d['stats']['servers'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">with recorded crashes</p>
        </x-filament::section>
    </div>

    <x-filament::section>
        <x-slot name="heading">Audit log</x-slot>
        <x-slot name="description">
            Every detected crash across servers, panel and infrastructure. Last watchdog scan:
            {{ $d['meta']['last_scan'] ?? 'never' }}. Excerpts are compressed automatically, entries are kept for 30 days.
        </x-slot>

        <div class="mb-4 flex flex-wrap gap-2">
            @foreach(['all' => 'All', 'server' => 'Servers', 'panel' => 'Panel', 'wings' => 'Wings', 'service' => 'Services'] as $key => $label)
                <button
                    type="button"
                    wire:click="$set('filter','{{ $key }}')"
                    @class([
                        'rounded-lg px-3 py-1.5 text-sm font-medium transition',
                        'bg-primary-600 text-white' => $filter === $key,
                        'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700' => $filter !== $key,
                    ])
                >
                    {{ $label }}
                </button>
            @endforeach
        </div>

        @php($events = array_values(array_filter($d['audit'], fn ($e) => $filter === 'all' || ($e['scope'] ?? '') === $filter)))

        @forelse($events as $e)
            @php($color = match($e['level'] ?? 'error') { 'critical' => 'danger', 'error' => 'warning', default => 'gray' })
            <div class="border-b border-gray-200 py-3 last:border-0 dark:border-white/10">
                <div class="flex flex-wrap items-center gap-2">
                    <span class="font-mono text-xs text-gray-500 dark:text-gray-400">{{ $e['iso'] }}</span>
                    <x-filament::badge :color="$color">{{ ucfirst($e['level'] ?? 'error') }}</x-filament::badge>
                    <span class="text-sm font-semibold">{{ $e['source'] }}</span>
                    @if(!empty($e['name']))
                        <span class="text-sm text-gray-500 dark:text-gray-400">· {{ $e['name'] }}</span>
                    @endif
                    @if(isset($e['exit_code']))
                        <span class="text-xs text-gray-500">exit {{ $e['exit_code'] }}</span>
                    @endif
                    @if(!empty($e['oom']))
                        <x-filament::badge color="danger">OOM</x-filament::badge>
                    @endif
                    <div class="ml-auto flex items-center gap-2">
                        <button
                            type="button"
                            wire:click="$set('detailId','{{ $detailId === $e['id'] ? '' : $e['id'] }}')"
                            class="text-sm text-primary-600 hover:underline dark:text-primary-400"
                        >
                            {{ $detailId === $e['id'] ? 'Hide details' : 'Details' }}
                        </button>
                        {{ ($this->exportAction($e['id'])) }}
                    </div>
                </div>
                @if($e['issue'])
                    <p class="mt-1 text-sm text-warning-600 dark:text-warning-400">
                        Detected: {{ $e['issue'] }}
                    </p>
                @else
                    <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                        No issue auto-detected — export the log for manual review.
                    </p>
                @endif
                @if($detailId === $e['id'])
                    @php($det = $this->getEventDetail($e['id']))
                    <pre class="mt-2 max-h-96 overflow-auto rounded-lg bg-gray-100 p-3 text-xs text-gray-800 dark:bg-gray-900 dark:text-gray-200">{{ $det['excerpt'] ?? '(no log excerpt available)' }}</pre>
                @endif
            </div>
        @empty
            <p class="text-gray-500 dark:text-gray-400">
                No events recorded yet — the watchdog checks every 5 minutes.
            </p>
        @endforelse
    </x-filament::section>
</x-filament-panels::page>
