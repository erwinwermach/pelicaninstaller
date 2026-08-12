<x-filament-panels::page>
    @php($d = $this->getData())

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <x-filament::section>
            <x-slot name="heading">Recorded crashes</x-slot>
            <p @class([
                'text-3xl font-bold',
                'text-danger-600 dark:text-danger-400' => $d['critical'] > 0,
                'text-success-600 dark:text-success-400' => $d['critical'] === 0,
            ])>{{ count($d['events']) }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">last 30 days</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Critical</x-slot>
            <p @class([
                'text-3xl font-bold',
                'text-danger-600 dark:text-danger-400' => $d['critical'] > 0,
            ])>{{ $d['critical'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">crashes / OOM / segfaults</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Last crash</x-slot>
            @if($d['last'])
                <p class="text-lg font-semibold">{{ $d['last']['iso'] }}</p>
                <p class="text-sm text-gray-500 dark:text-gray-400">{{ $d['last']['source'] }}</p>
            @else
                <p class="text-gray-500 dark:text-gray-400">No crashes recorded.</p>
            @endif
        </x-filament::section>
    </div>

    <x-filament::section>
        <x-slot name="heading">Crash history</x-slot>
        <x-slot name="description">Detected by the host watchdog every 5 minutes. Works for every egg/game. Kept for 30 days, then cleaned up automatically.</x-slot>
        @forelse($d['events'] as $e)
            @php($color = match($e['level'] ?? 'error') { 'critical' => 'danger', 'error' => 'warning', default => 'gray' })
            <div class="border-b border-gray-200 py-3 last:border-0 dark:border-white/10">
                <div class="flex flex-wrap items-center gap-2">
                    <span class="font-mono text-xs text-gray-500 dark:text-gray-400">{{ $e['iso'] }}</span>
                    <x-filament::badge :color="$color">{{ ucfirst($e['level'] ?? 'error') }}</x-filament::badge>
                    <span class="text-sm font-semibold">{{ $e['source'] }}</span>
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
                No crashes recorded for this server — the watchdog has not detected anything (checks every 5 minutes).
            </p>
        @endforelse
    </x-filament::section>
</x-filament-panels::page>
