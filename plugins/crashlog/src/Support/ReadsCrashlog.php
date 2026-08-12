<?php

namespace Pelicaninstaller\Crashlog\Support;

use Illuminate\Support\Facades\File;

trait ReadsCrashlog
{
    protected function readJson(string $path): array
    {
        if (!File::exists($path)) {
            return [];
        }

        $data = json_decode(File::get($path), true);

        return is_array($data) ? $data : [];
    }

    public function getEventDetail(string $id): ?array
    {
        $event = $this->readJson('/var/www/pelican/storage/app/crashlog/events/' . basename($id) . '.json');
        if (empty($event)) {
            return null;
        }

        $event['excerpt'] = $this->decodeExcerpt($event);

        return $event;
    }

    public function decodeExcerpt(array $event): string
    {
        $raw = base64_decode((string) ($event['excerpt_b64'] ?? ''), true);
        if ($raw === false) {
            return '';
        }

        if (!empty($event['excerpt_gz']) && function_exists('gzdecode')) {
            $decoded = @gzdecode($raw);
            if ($decoded !== false) {
                return $decoded;
            }
        }

        return $raw;
    }

    public function formatEvent(?array $e): string
    {
        if (empty($e)) {
            return "Event not found.\n";
        }

        return sprintf(
            "[%s] %s %s%s\nSource: %s\nServer: %s (%s)\nIssue: %s\n\n%s\n",
            $e['iso'] ?? '?',
            strtoupper($e['level'] ?? '?'),
            $e['scope'] ?? '?',
            isset($e['exit_code']) ? ' exit=' . $e['exit_code'] : '',
            $e['source'] ?? '?',
            $e['server'] ?? '-',
            $e['name'] ?? '-',
            $e['issue'] ?? 'not auto-detected',
            $e['excerpt'] ?? '(no log excerpt)',
        );
    }
}
