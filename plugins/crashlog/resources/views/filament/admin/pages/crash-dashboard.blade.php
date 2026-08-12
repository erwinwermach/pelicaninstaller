<x-filament-panels::page>
    @php($d = $this->getData())

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <x-filament::section>
            <x-slot name="heading">Total events</x-slot>
            <p class="text-3xl font-bold">{{ $d['stats']['total'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">last 30 days</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Crashes</x-slot>
            <p @class([
                'text-3xl font-bold',
                'text-danger-600 dark:text-danger-400' => $d['stats']['critical'] > 0,
            ])>{{ $d['stats']['critical'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">critical / OOM / segfaults</p>
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

    @if($d['last'] && !empty($d['last']['issue']))
        <x-filament::section>
            <x-slot name="heading">Diagnosis — latest issue</x-slot>
            <p class="text-warning-600 dark:text-warning-400">{{ $d['last']['issue'] }}</p>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                {{ $d['last']['source'] }} · {{ $d['last']['iso'] }}
                @if(!empty($d['last']['name']))
                    · {{ $d['last']['name'] }}
                @endif
            </p>
            @if(!empty($d['last']['preview']))
                <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">{{ $d['last']['preview'] }}</p>
            @endif
        </x-filament::section>
    @endif

    <x-filament::section>
        <x-slot name="heading">Timeline</x-slot>
        <x-slot name="description">
            Every detected crash across servers, panel and infrastructure. Last watchdog scan:
            {{ $d['meta']['last_scan'] ?? 'never' }}. Excerpts are compressed automatically, entries are kept for 30 days.
        </x-slot>

        <div class="mb-4 flex flex-wrap items-center gap-2">
            <span class="text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">Source</span>
            @foreach(['all' => 'All', 'server' => 'Servers', 'panel' => 'Panel', 'wings' => 'Wings', 'service' => 'Services'] as $key => $label)
                <button
                    type="button"
                    wire:click="$set('scopeFilter','{{ $key }}')"
                    @class([
                        'rounded-lg px-3 py-1.5 text-sm font-medium transition',
                        'bg-primary-600 text-white' => $scopeFilter === $key,
                        'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700' => $scopeFilter !== $key,
                    ])
                >
                    {{ $label }}
                </button>
            @endforeach
            <span class="ml-4 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">Type</span>
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

        @php($events = array_values(array_filter($d['audit'], function ($e) use ($scopeFilter, $levelFilter) {
            if ($scopeFilter !== 'all' && ($e['scope'] ?? '') !== $scopeFilter) {
                return false;
            }
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
                                    <button
                                        type="button"
                                        wire:click="download('{{ $e['id'] }}')"
                                        class="rounded-lg bg-gray-100 px-2.5 py-1 text-xs font-medium text-gray-700 transition hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
                                    >
                                        Export
                                    </button>
                                    <button
                                        type="button"
                                        wire:click="upload('{{ $e['id'] }}')"
                                        class="rounded-lg bg-gray-100 px-2.5 py-1 text-xs font-medium text-gray-700 transition hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
                                    >
                                        Upload
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
                @if(count($d['audit']) === 0)
                    No events recorded yet — the watchdog checks every 5 minutes.
                @else
                    Nothing matches these filters.
                @endif
            </p>
        @endforelse
    </x-filament::section>

    <div x-data @copylink.window="navigator.clipboard.writeText($event.detail.url)"></div>

    @if($uploadedUrl)
        <x-filament::section>
            <x-slot name="heading">Uploaded log</x-slot>
            <div class="flex flex-wrap items-center gap-3">
                <a href="{{ $uploadedUrl }}" target="_blank" class="text-primary-600 underline dark:text-primary-400">{{ $uploadedUrl }}</a>
                <button
                    type="button"
                    x-data="{ copied: false }"
                    @click="navigator.clipboard.writeText('{{ $uploadedUrl }}'); copied = true; setTimeout(() => copied = false, 2000)"
                    class="rounded-lg bg-gray-100 px-3 py-1.5 text-xs font-medium text-gray-700 transition hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
                >
                    <span x-show="!copied">Copy link</span>
                    <span x-show="copied" class="text-success-600">Copied!</span>
                </button>
            </div>
        </x-filament::section>
    @endif
</x-filament-panels::page>
