<x-filament-panels::page>
    @php($d = $this->getData())

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-4">
        <x-filament::section>
            <x-slot name="heading">Recorded crashes</x-slot>
            <p class="text-3xl font-bold">{{ count($d['events']) }}</p>
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
            <x-slot name="heading">Crashes (last hour)</x-slot>
            <p @class([
                'text-3xl font-bold',
                'text-danger-600 dark:text-danger-400' => $d['loop_risk'],
            ])>{{ $d['recent_critical'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">
                {{ $d['loop_risk'] ? 'crash loop risk' : 'normal' }}
            </p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Last crash</x-slot>
            @if($d['last'])
                <p class="text-lg font-semibold">{{ substr($d['last']['iso'] ?? '', 11, 8) }} · {{ substr($d['last']['iso'] ?? '', 0, 10) }}</p>
                <p class="text-sm text-gray-500 dark:text-gray-400">{{ $d['last']['source'] }}</p>
            @else
                <p class="text-gray-500 dark:text-gray-400">No crashes recorded.</p>
            @endif
        </x-filament::section>
    </div>

    @if($d['last'] && !empty($d['last']['issue']))
        <x-filament::section>
            <x-slot name="heading">Diagnosis — latest crash</x-slot>
            <p class="text-warning-600 dark:text-warning-400">{{ $d['last']['issue'] }}</p>
            @if(!empty($d['last']['preview']))
                <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">{{ $d['last']['preview'] }}</p>
            @endif
        </x-filament::section>
    @endif

    <x-filament::section>
        <x-slot name="heading">Timeline</x-slot>
        <x-slot name="description">Detected by the host watchdog every 5 minutes. Works for every egg/game. Entries are kept for 30 days and cleaned up automatically.</x-slot>

        <div class="mb-4 flex flex-wrap gap-2">
            @foreach(['all' => 'All', 'crash' => 'Crashes', 'error' => 'Errors', 'warning' => 'Warnings'] as $key => $label)
                <button
                    type="button"
                    wire:click="$set('levelFilter','{{ $key }}')"
                    @class([
                        'rounded-lg px-3 py-1.5 text-sm font-medium transition',
                        'bg-primary-600 text-white' => $levelFilter === $key,
                        'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700' => $levelFilter !== $key,
                    ])
                >
                    {{ $label }}
                </button>
            @endforeach
        </div>

        @php($events = array_values(array_filter($d['events'], function ($e) use ($levelFilter) {
            $lvl = $e['level'] ?? 'error';
            if ($levelFilter === 'all') {
                return true;
            }
            if ($levelFilter === 'crash') {
                return $lvl === 'critical';
            }
            return $lvl === $levelFilter;
        })))
        @php($groups = [])
        @foreach($events as $e)
            @php($day = substr($e['iso'] ?? '', 0, 10))
            @php($groups[$day][] = $e)
        @endforeach

        @forelse($groups as $day => $dayEvents)
            @php($date = \Illuminate\Support\Carbon::parse($day . 'T00:00:00Z'))
            <div class="mt-6 first:mt-0">
                <p class="mb-3 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    {{ $date->isToday() ? 'Today' : ($date->isYesterday() ? 'Yesterday' : $date->format('l, M j')) }}
                </p>
                <div class="relative space-y-5 border-l-2 border-gray-200 pl-6 dark:border-white/10">
                    @foreach($dayEvents as $e)
                        @php($color = match($e['level'] ?? 'error') { 'critical' => 'danger', 'error' => 'warning', default => 'gray' })
                        @php($dot = ['danger' => 'bg-danger-500', 'warning' => 'bg-warning-500', 'gray' => 'bg-gray-400'][$color])
                        <div class="relative">
                            <span class="absolute -left-[31px] top-1.5 h-3 w-3 rounded-full {{ $dot }}"></span>
                            <div class="flex flex-wrap items-center gap-2">
                                <span class="font-mono text-xs text-gray-500 dark:text-gray-400">{{ substr($e['iso'] ?? '', 11, 8) }}</span>
                                <x-filament::badge :color="$color">
                                    {{ $e['level'] === 'critical' ? 'Crash' : ucfirst($e['level'] ?? 'Error') }}
                                </x-filament::badge>
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
                                    <button
                                        type="button"
                                        wire:click="download('{{ $e['id'] }}')"
                                        class="rounded-lg bg-gray-100 px-2.5 py-1 text-xs font-medium text-gray-700 transition hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
                                    >
                                        Export
                                    </button>
                                </div>
                            </div>
                            @if($e['issue'])
                                <p class="mt-1 text-sm text-warning-600 dark:text-warning-400">
                                    ▲ {{ $e['issue'] }}
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
                    @endforeach
                </div>
            </div>
        @empty
            <p class="text-gray-500 dark:text-gray-400">
                @if(count($d['events']) === 0)
                    No crashes recorded for this server — the watchdog has not detected anything (checks every 5 minutes).
                @else
                    Nothing matches this filter.
                @endif
            </p>
        @endforelse
    </x-filament::section>
</x-filament-panels::page>
