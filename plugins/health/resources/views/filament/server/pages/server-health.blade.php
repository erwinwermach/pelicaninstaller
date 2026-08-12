<x-filament-panels::page>
    @php($d = $this->getData())

    <x-filament::section>
        <x-slot name="heading">Server jar</x-slot>
        @if($d['jar'])
            @if($d['jar']['jar_ok'] ?? false)
                <p class="font-semibold text-success-600 dark:text-success-400">Healthy</p>
            @else
                <p class="font-semibold text-danger-600 dark:text-danger-400">Broken / missing</p>
            @endif
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
                {{ $d['jar']['jarfile'] ?? '?' }} · {{ number_format(($d['jar']['size'] ?? 0) / 1024 / 1024, 1) }} MB
                @if($d['jar']['fixed'] ?? false) · <span class="text-success-600">was repaired automatically</span> @endif
            </p>
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
                The watchdog checks and repairs server jars every 5 minutes.
            </p>
        @else
            <p class="text-gray-500 dark:text-gray-400">No report yet — the watchdog has not processed this server (runs every 5 minutes).</p>
        @endif
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">Playit address</x-slot>
        @forelse($d['addresses'] as $a)
            <p class="text-lg font-semibold text-success-600 dark:text-success-400">
                {{ $a['address'] }}
                <span class="text-sm font-normal text-gray-500 dark:text-gray-400">(port {{ $a['port'] }})</span>
            </p>
            <p class="text-sm text-gray-500 dark:text-gray-400">Players join this address.</p>
        @empty
            <p class="text-warning-600 dark:text-warning-400">
                No playit tunnel yet — create one at playit.gg (game type, local port of this server).
            </p>
        @endforelse
    </x-filament::section>

    <x-filament::section>
        <x-slot name="heading">Cloudflare</x-slot>
        @if($d['cf_app_routing'])
            <p class="font-semibold text-success-600 dark:text-success-400">
                HTTP apps enabled — app-&lt;port&gt;.{{ $d['domain'] ?? 'your-domain' }}
            </p>
        @else
            <p class="text-gray-500 dark:text-gray-400">
                HTTP app routing is off (set CF_APP_ROUTING=yes in /etc/pelican-installer/installer.conf).
                Cloudflare only serves HTTP ports publicly; game TCP/UDP uses playit.
            </p>
        @endif
    </x-filament::section>
</x-filament-panels::page>
