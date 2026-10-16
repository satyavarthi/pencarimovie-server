#!/bin/sh
set -e

export MALLOC_ARENA_MAX=2
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/caddy/data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/caddy/config}"

# Container memory optimization: auto-detect cgroup memory limits (Heroku, Docker, K8s, Fly.io)
# to prevent OOM/R14 and balance thread concurrency with available RAM.
export GODEBUG="${GODEBUG:-madvdontneed=1}"
export GOGC="${GOGC:-80}"

MEM_LIMIT=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "")
if [ "$MEM_LIMIT" = "max" ]; then
    MEM_LIMIT=""
fi

# On 64-bit systems, unlimited memory in cgroup v1 is 9223372036854771712 or 9223372036854775807
if [ -n "$MEM_LIMIT" ] && [ "$MEM_LIMIT" -gt 0 ] 2>/dev/null && [ "$MEM_LIMIT" -le 34359738368 ]; then
    MEM_MB=$((MEM_LIMIT / 1024 / 1024))

    if [ "$MEM_MB" -le 512 ]; then
        # Measured (Heroku-shaped 512MB cgroup, 4 threads/max 6, wait 15s):
        # cold-origin catalog searches hit p50 11s / p95 17s and returned HTTP
        # 503, because the tiny pool was shared by catalog traffic AND by stream
        # requests that hold their worker for the whole playback. Rebalance:
        #   - cheaper Go heap (256MiB) leaves headroom for PHP worker threads;
        #   - 6 -> 8 threads so a few viewers no longer starve catalog requests;
        #   - 64M per-request ceiling (a catalog thread uses far less than 96M);
        #   - fail fast in 10s: a client can retry a 503, whereas Heroku kills a
        #     request at 30s with H12 and counts it against the app.
        export GOMEMLIMIT="${GOMEMLIMIT:-256MiB}"
        export FRANKENPHP_NUM_THREADS="${FRANKENPHP_NUM_THREADS:-6}"
        export FRANKENPHP_MAX_THREADS="${FRANKENPHP_MAX_THREADS:-8}"
        export PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-64M}"
        export FRANKENPHP_MAX_WAIT_TIME="${FRANKENPHP_MAX_WAIT_TIME:-10s}"
        export FD_DOWNLOAD_PARALLEL_CHUNKS="${FD_DOWNLOAD_PARALLEL_CHUNKS:-2}"
    elif [ "$MEM_MB" -le 1024 ]; then
        # A stream holds its worker for the whole playback, so the pool size IS
        # the concurrent-viewer limit. Measured: 8 threads cost only ~70MB RSS
        # under a 50-way burst of catalog requests, so threads are far cheaper
        # than they look and 10/16 is safe inside 1GB with a 550MiB Go ceiling.
        export GOMEMLIMIT="${GOMEMLIMIT:-550MiB}"
        export FRANKENPHP_NUM_THREADS="${FRANKENPHP_NUM_THREADS:-10}"
        export FRANKENPHP_MAX_THREADS="${FRANKENPHP_MAX_THREADS:-16}"
        export PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-128M}"
        export FRANKENPHP_MAX_WAIT_TIME="${FRANKENPHP_MAX_WAIT_TIME:-20s}"
        export FD_DOWNLOAD_PARALLEL_CHUNKS="${FD_DOWNLOAD_PARALLEL_CHUNKS:-2}"
    else
        TARGET_GOMEM=$((MEM_MB * 85 / 100))
        export GOMEMLIMIT="${GOMEMLIMIT:-${TARGET_GOMEM}MiB}"
        export FRANKENPHP_NUM_THREADS="${FRANKENPHP_NUM_THREADS:-16}"
        export FRANKENPHP_MAX_THREADS="${FRANKENPHP_MAX_THREADS:-32}"
        export PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-256M}"
        export FRANKENPHP_MAX_WAIT_TIME="${FRANKENPHP_MAX_WAIT_TIME:-20s}"
        export FD_DOWNLOAD_PARALLEL_CHUNKS="${FD_DOWNLOAD_PARALLEL_CHUNKS:-3}"
    fi
elif [ -n "$DYNO" ]; then
    # Fallback default for Heroku dynos if cgroup read was empty. Standard-2X
    # dynos have ~1GB, so use the 1GB profile rather than the smallest one.
    export GOMEMLIMIT="${GOMEMLIMIT:-550MiB}"
    export FRANKENPHP_NUM_THREADS="${FRANKENPHP_NUM_THREADS:-10}"
    export FRANKENPHP_MAX_THREADS="${FRANKENPHP_MAX_THREADS:-16}"
    export PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-128M}"
    export FRANKENPHP_MAX_WAIT_TIME="${FRANKENPHP_MAX_WAIT_TIME:-20s}"
    export FD_DOWNLOAD_PARALLEL_CHUNKS="${FD_DOWNLOAD_PARALLEL_CHUNKS:-2}"
fi

mkdir -p /tmp/caddy/data /tmp/caddy/config /app/storage 2>/dev/null || true
chmod 777 /app/storage 2>/dev/null || true

# FrankenPHP 1.13.0+ compatibility: ensure entry.php handles os.Args[0] (frankenphp) being prepended to argv
ENTRY="/app/vendor/danog/madelineproto/src/Ipc/Runner/entry.php"
if [ -f "$ENTRY" ] && ! grep -q "str_ends_with(\$arguments\[0\]" "$ENTRY" 2>/dev/null; then
    sed -i 's/\$arguments = \\array_slice(\$GLOBALS\['\''argv'\''\], 1);/\$arguments = \\array_slice(\$GLOBALS\['\''argv'\''\], 1); if (isset(\$arguments[0]) \&\& (\\str_ends_with(\$arguments[0], '\''.php'\'') || (isset(\$arguments[1]) \&\& \\in_array(\$arguments[1], ['\''madeline-ipc'\'', '\''madeline-worker'\''], true)))) { \\array_shift(\$arguments); }/g' "$ENTRY" 2>/dev/null || true
fi

# If custom arguments were passed (and not self or 'start'), execute them
if [ $# -gt 0 ] && [ "$1" != "/usr/local/bin/docker-entrypoint.sh" ] && [ "$1" != "start" ]; then
    exec "$@"
fi

# 2. Start FrankenPHP server
PORT="${PORT:-8088}"
echo "[Docker] Starting PencariMovie Server on 0.0.0.0:${PORT}..."
if [ -f "/app/Caddyfile" ]; then
    CADDYFILE="/tmp/Caddyfile"
    JSON="/tmp/caddy.json"
    cp /app/Caddyfile "$CADDYFILE"
    # NOTE: the Caddyfile must NOT contain `request_body_timeout` in php_server.
    # This FrankenPHP build only accepts: hot_reload, name, root, split, env,
    # resolve_root_symlink, worker. The directive was removed from the repo
    # Caddyfile, so no strip-and-retry workaround is needed here anymore.
    #
    # Caddy 2.10 defaults timeouts.request to 60s ("maximum request handling
    # time exceeded"), which would abort long media streams. Inject request:0
    # into the adapted JSON when a timeouts block is present.
    adapt() {
        /app/bin/frankenphp adapt --config "$CADDYFILE" --adapter caddyfile > "$JSON" 2>/tmp/caddy-adapt.err
    }
    if ! adapt; then
        cat /tmp/caddy-adapt.err >&2 2>/dev/null || true
    fi
    if grep -q '"timeouts"' "$JSON" 2>/dev/null; then
        sed -i 's/"timeouts":{/"timeouts":{"request":0,/g' "$JSON"
        exec /app/bin/frankenphp run --config "$JSON"
    fi
    exec /app/bin/frankenphp run --config "$CADDYFILE"
else
    exec /app/bin/frankenphp php-server --listen "0.0.0.0:${PORT:-8088}" --root /app
fi
