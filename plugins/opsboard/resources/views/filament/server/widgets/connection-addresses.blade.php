<div class="fi-section">
    <div class="fi-section-content-ctn">
        <div class="fi-section-content p-4">
            @php($addresses = $this->getAddresses())
            @if(count($addresses) > 0)
                <p class="mb-2 text-sm text-gray-500 dark:text-gray-400">
                    Players join via these addresses:
                </p>
                @foreach($addresses as $a)
                    <p class="text-lg font-semibold text-success-600 dark:text-success-400">
                        {{ $a['address'] }}
                        <span class="text-sm font-normal text-gray-500 dark:text-gray-400">
                            (port {{ $a['port'] }}{{ !empty($a['backend']) ? ' · ' . $a['backend'] : '' }})
                        </span>
                    </p>
                @endforeach
            @else
                <p class="text-sm text-warning-600 dark:text-warning-400">
                    No public address yet — see the <strong>Connections</strong> page for details.
                </p>
            @endif
        </div>
    </div>
</div>
