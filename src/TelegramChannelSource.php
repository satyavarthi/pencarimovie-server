<?php
declare(strict_types=1);

/**
 * Local Telegram channel source manager.
 *
 * Sources are deliberately stored as metadata only. Media stays in Telegram;
 * playback uses the existing MadelineProto session and streams directly.
 */
final class TelegramChannelSource
{
    public static function normalize(string $url): array
    {
        $url = trim($url);
        if ($url === '') return ['url' => '', 'type' => '', 'peer' => '', 'invite_hash' => ''];

        if (preg_match('#^https?://t\.me/(?:\+|joinchat/)([A-Za-z0-9_-]+)#i', $url, $m)) {
            return [
                'url' => $url,
                'type' => 'private',
                'peer' => '',
                'invite_hash' => $m[1],
            ];
        }

        if (preg_match('#^https?://t\.me/([A-Za-z0-9_]{4,})(?:/)?$#i', $url, $m)) {
            return [
                'url' => 'https://t.me/' . $m[1],
                'type' => 'public',
                'peer' => '@' . $m[1],
                'invite_hash' => '',
            ];
        }

        return ['url' => '', 'type' => '', 'peer' => '', 'invite_hash' => ''];
    }

    public static function id(string $url): string
    {
        return 'tg_' . substr(hash('sha256', strtolower(trim($url))), 0, 16);
    }

    public static function indexPath(): string
    {
        return fd_storage_path('storage/telegram_channel_index.json');
    }

    public static function loadIndex(): array
    {
        $path = self::indexPath();
        if (!is_file($path)) return [];
        $data = json_decode((string) @file_get_contents($path), true);
        return is_array($data) ? $data : [];
    }

    public static function saveIndex(array $rows): bool
    {
        $path = self::indexPath();
        $dir = dirname($path);
        if (!is_dir($dir)) @mkdir($dir, 0777, true);
        return @file_put_contents(
            $path,
            json_encode(array_values($rows), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
            LOCK_EX
        ) !== false;
    }

    private static function fileName(array $message): string
    {
        $media = $message['media'] ?? [];
        $document = $media['document'] ?? [];
        foreach ((array) ($document['attributes'] ?? []) as $attr) {
            if (($attr['_'] ?? '') === 'documentAttributeFilename' && !empty($attr['file_name'])) {
                return trim((string) $attr['file_name']);
            }
        }
        $caption = trim((string) ($message['message'] ?? ''));
        if ($caption !== '') {
            $line = trim((string) preg_replace('/\s+/u', ' ', strtok($caption, "\n")));
            if ($line !== '') return mb_substr($line, 0, 180);
        }
        $mime = (string) ($document['mime_type'] ?? '');
        $ext = $mime !== '' ? (string) (pathinfo($mime, PATHINFO_EXTENSION) ?: '') : '';
        return 'Telegram file ' . (string) ($message['id'] ?? '') . ($ext ? '.' . $ext : '');
    }

    private static function mediaInfo(array $message): ?array
    {
        $media = $message['media'] ?? null;
        if (!is_array($media)) return null;
        $kind = (string) ($media['_'] ?? '');

        if ($kind === 'messageMediaDocument' && !empty($media['document']) && is_array($media['document'])) {
            $doc = $media['document'];
            $name = self::fileName($message);
            $mime = (string) ($doc['mime_type'] ?? 'application/octet-stream');
            $size = (int) ($doc['size'] ?? 0);
            $video = null;
            foreach ((array) ($doc['attributes'] ?? []) as $attr) {
                if (($attr['_'] ?? '') === 'documentAttributeVideo') {
                    $video = $attr;
                    break;
                }
            }
            return [
                'kind' => 'document',
                'name' => $name,
                'mime' => $mime,
                'size' => $size,
                'duration' => (int) ($video['duration'] ?? 0),
                'width' => (int) ($video['w'] ?? 0),
                'height' => (int) ($video['h'] ?? 0),
            ];
        }

        if ($kind === 'messageMediaPhoto' && !empty($media['photo'])) {
            return [
                'kind' => 'photo',
                'name' => 'Telegram photo ' . (string) ($message['id'] ?? '') . '.jpg',
                'mime' => 'image/jpeg',
                'size' => 0,
                'duration' => 0,
                'width' => 0,
                'height' => 0,
            ];
        }

        return null;
    }

    public static function scan(object $api, array $source, int $maxMessages = 500): array
    {
        $normalized = self::normalize((string) ($source['url'] ?? ''));
        if ($normalized['url'] === '') throw new \RuntimeException('Invalid Telegram source URL.');

        $peer = $normalized['peer'];
        if ($normalized['type'] === 'private' && $normalized['invite_hash'] !== '') {
            try {
                $import = $api->messages->importChatInvite(hash: $normalized['invite_hash']);
                $chat = $import['chats'][0] ?? null;
                if (is_array($chat) && isset($chat['id'])) {
                    $peer = (int) $chat['id'];
                    if (($chat['_'] ?? '') === 'channel') {
                        $peer = -100 . (string) $chat['id'];
                    }
                }
            } catch (\Throwable $e) {
                // If already joined, resolving the invite can fail. Keep the
                // invite URL as the peer and let getHistory report the real access error.
                $peer = (string) ($source['peer'] ?? '');
                if ($peer === '') $peer = (string) ($source['url'] ?? '');
            }
        }

        if ($peer === '') $peer = (string) ($source['url'] ?? '');

        // Resolve/validate access before indexing.
        try {
            $full = $api->getFullInfo($peer);
            $chat = $full['Chat'] ?? $full['chat'] ?? [];
            $title = (string) ($chat['title'] ?? $source['name'] ?? $peer);
            $resolvedPeer = $chat['id'] ?? $peer;
            if (($chat['_'] ?? '') === 'channel' && is_numeric($resolvedPeer)) {
                $resolvedPeer = -100 . (string) $resolvedPeer;
            }
            if ($resolvedPeer !== '') $peer = $resolvedPeer;
        } catch (\Throwable $e) {
            throw new \RuntimeException('Telegram access failed: ' . $e->getMessage(), 0, $e);
        }

        $rows = [];
        $offsetId = 0;
        $remaining = max(1, min(5000, $maxMessages));

        while ($remaining > 0) {
            $limit = min(100, $remaining);
            $history = $api->messages->getHistory(
                peer: $peer,
                offset_id: $offsetId,
                offset_date: 0,
                add_offset: 0,
                limit: $limit,
                max_id: 0,
                min_id: 0,
                hash: 0
            );
            $messages = (array) ($history['messages'] ?? []);
            if (!$messages) break;

            foreach ($messages as $message) {
                if (!is_array($message) || ($message['_'] ?? '') === 'messageEmpty') continue;
                $media = self::mediaInfo($message);
                if ($media === null) continue;

                $msgId = (int) ($message['id'] ?? 0);
                if ($msgId <= 0) continue;
                $sourceId = (string) ($source['id'] ?? self::id($normalized['url']));
                $rows[] = [
                    'short_code' => $sourceId . '_' . $msgId,
                    'source_id' => $sourceId,
                    'source_url' => $normalized['url'],
                    'source_type' => $normalized['type'],
                    'peer' => (string) $peer,
                    'message_id' => $msgId,
                    'title' => $media['name'],
                    'caption' => (string) ($message['message'] ?? ''),
                    'file_name' => $media['name'],
                    'file_type' => $media['mime'],
                    'file_size' => $media['size'],
                    'duration' => $media['duration'],
                    'width' => $media['width'],
                    'height' => $media['height'],
                    'date' => (int) ($message['date'] ?? 0),
                    'year' => !empty($message['date']) ? date('Y', (int) $message['date']) : '',
                    'kind' => $media['kind'],
                    'indexed_at' => time(),
                ];
            }

            $lastId = (int) ($messages[count($messages) - 1]['id'] ?? 0);
            if ($lastId <= 0 || count($messages) < $limit) break;
            $offsetId = $lastId;
            $remaining -= count($messages);
        }

        return [
            'title' => $title ?? ($source['name'] ?? $normalized['url']),
            'peer' => (string) $peer,
            'files' => $rows,
        ];
    }
}
