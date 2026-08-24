<x-filament-panels::page>
    @php($d = $this->getData())

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <x-filament::section>
            <x-slot name="heading">Recorded</x-slot>
            <p class="text-3xl font-bold">{{ $d['matched'] }}</p>
            <p class="text-sm text-gray-500 dark:text-gray-400">events, last 30 days</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Crashes</x-slot>
            <p class="text-3xl font-bold {{ $d['critical'] > 0 ? 'text-danger-600 dark:text-danger-400' : '' }}">
                {{ $d['critical'] }}
            </p>
            <p class="text-sm text-gray-500 dark:text-gray-400">critical / OOM / segfaults</p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Last hour</x-slot>
            <p class="text-3xl font-bold {{ $d['loop_risk'] ? 'text-danger-600 dark:text-danger-400' : '' }}">
                {{ $d['recent_critical'] }}
            </p>
            <p class="text-sm text-gray-500 dark:text-gray-400">
                {{ $d['loop_risk'] ? 'crash loop risk' : 'normal' }}
            </p>
        </x-filament::section>
        <x-filament::section>
            <x-slot name="heading">Last event</x-slot>
            @if($d['last'])
                <p class="font-semibold">{{ substr($d['last']['iso'] ?? '', 11, 8) }} UTC</p>
                <p class="text-sm text-gray-500 dark:text-gray-400">{{ $d['last']['source'] }}</p>
            @else
                <p class="text-lg font-semibold text-success-600 dark:text-success-400">None</p>
                <p class="text-sm text-gray-500 dark:text-gray-400">no crashes recorded</p>
            @endif
        </x-filament::section>
    </div>

    @if(!empty($d['last']['issue']))
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
        <x-slot name="description">
            Detected by the host watchdog every 5 minutes. Works for every egg and game.
        </x-slot>

        <div class="mb-4 flex flex-wrap gap-2">
            @foreach(['all' => 'All', 'crash' => 'Crashes', 'error' => 'Errors', 'warning' => 'Warnings'] as $key => $label)
                <x-filament::button
                    color="gray"
                    size="xs"
                    :filled="$levelFilter === $key"
                    wire:click="$set('levelFilter', '{{ $key }}')"
                >
                    {{ $label }}
                </x-filament::button>
            @endforeach
        </div>

        <div class="relative space-y-5 border-l-2 border-gray-200 pl-6 dark:border-white/10">
            @forelse($d['events'] as $e)
                @php($color = match($e['level'] ?? 'error') { 'critical' => 'danger', 'error' => 'warning', default => 'gray' })
                @php($dot = ['danger' => 'bg-danger-500', 'warning' => 'bg-warning-500', 'gray' => 'bg-gray-400'][$color])
                <div class="relative">
                    <span class="absolute -left-[31px] top-1.5 h-3 w-3 rounded-full {{ $dot }}"></span>
                    <div class="flex flex-wrap items-center gap-2">
                        <span class="font-mono text-xs text-gray-500 dark:text-gray-400">{{ substr($e['iso'] ?? '', 11, 8) }}</span>
                        <x-filament::badge :color="$color">
                            {{ ($e['level'] ?? '') === 'critical' ? 'Crash' : ucfirst($e['level'] ?? 'Error') }}
                        </x-filament::badge>
                        <span class="text-sm font-semibold">{{ $e['source'] }}</span>
                        @if(isset($e['exit_code']))
                            <span class="text-xs text-gray-500 dark:text-gray-400">exit {{ $e['exit_code'] }}</span>
                        @endif
                        @if(!empty($e['oom']))
                            <x-filament::badge color="danger">OOM</x-filament::badge>
                        @endif
                        <div class="ml-auto flex flex-wrap items-center gap-2">
                            <x-filament::button
                                color="gray"
                                size="xs"
                                wire:click="$set('detailId', '{{ $detailId === $e['id'] ? '' : $e['id'] }}')"
                            >
                                {{ $detailId === $e['id'] ? 'Hide details' : 'Details' }}
                            </x-filament::button>
                            <x-filament::button
                                color="gray"
                                size="xs"
                                icon="tabler-download"
                                wire:click="download('{{ $e['id'] }}')"
                            >
                                Export
                            </x-filament::button>
                            <x-filament::button
                                color="gray"
                                size="xs"
                                icon="tabler-cloud-upload"
                                wire:click="upload('{{ $e['id'] }}')"
                            >
                                Upload
                            </x-filament::button>
                        </div>
                    </div>
                    @if($e['issue'])
                        <p class="mt-1 text-sm text-warning-600 dark:text-warning-400">{{ $e['issue'] }}</p>
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
                <p class="py-4 text-gray-500 dark:text-gray-400">
                    @if(($d['matched'] ?? 0) === 0)
                        No crashes recorded for this server — the watchdog has not detected anything.
                    @else
                        Nothing matches this filter.
                    @endif
                </p>
            @endforelse
        </div>

        @if(($d['page_count'] ?? 1) > 1)
            <div class="mt-5 flex items-center justify-between">
                <p class="text-sm text-gray-500 dark:text-gray-400">
                    page {{ $d['page'] }} of {{ $d['page_count'] }}
                </p>
                <div class="flex gap-2">
                    <x-filament::button
                        color="gray"
                        size="sm"
                        icon="tabler-chevron-left"
                        :disabled="$d['page'] <= 1"
                        wire:click="$set('page', {{ max(1, $d['page'] - 1) }})"
                    >
                        Previous
                    </x-filament::button>
                    <x-filament::button
                        color="gray"
                        size="sm"
                        icon-position="after"
                        icon="tabler-chevron-right"
                        :disabled="$d['page'] >= $d['page_count']"
                        wire:click="$set('page', {{ min($d['page_count'], $d['page'] + 1) }})"
                    >
                        Next
                    </x-filament::button>
                </div>
            </div>
        @endif
    </x-filament::section>

    @if($uploadedUrl)
        <x-filament::section>
            <x-slot name="heading">Uploaded log</x-slot>
            <div x-data="{ copied: false }" class="flex flex-wrap items-center gap-3">
                <a href="{{ $uploadedUrl }}" target="_blank" class="text-primary-600 underline dark:text-primary-400">{{ $uploadedUrl }}</a>
                <x-filament::button
                    color="gray"
                    size="xs"
                    x-on:click="navigator.clipboard.writeText('{{ $uploadedUrl }}'); copied = true; setTimeout(() => copied = false, 2000)"
                >
                    <span x-show="!copied">Copy link</span>
                    <span x-show="copied" x-cloak>Copied!</span>
                </x-filament::button>
            </div>
        </x-filament::section>
    @endif
</x-filament-panels::page>
