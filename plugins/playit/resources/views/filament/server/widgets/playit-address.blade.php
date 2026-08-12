<div class="fi-section">
    <div class="fi-section-content-ctn">
        <div class="fi-section-content p-4">
            @php($addresses = $this->getAddresses())
            @if(count($addresses) > 0)
                <p class="text-sm text-gray-500 dark:text-gray-400 mb-2">
                    Players join your server via playit.gg:
                </p>
                @foreach($addresses as $a)
                    <p class="text-lg font-semibold text-success-600 dark:text-success-400">
                        {{ $a['address'] }}
                        <span class="text-sm font-normal text-gray-500 dark:text-gray-400">
                            (port {{ $a['port'] }})
                        </span>
                    </p>
                @endforeach
            @else
                <p class="text-sm text-warning-600 dark:text-warning-400">
                    No playit.gg address yet — open the <strong>Playit</strong> page for this server to create one.
                </p>
            @endif
        </div>
    </div>
</div>
