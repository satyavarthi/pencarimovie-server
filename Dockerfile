# syntax=docker/dockerfile:1
# Multi-arch Dockerfile leveraging pre-packaged Linux releases (from scripts/build-release.bat)
# or fallback to local files + frankenphp static binary.

FROM debian:bookworm-slim

ARG TARGETARCH

# Install runtime dependencies (ca-certificates, curl, procps)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Check and extract pre-built tarball from dist/ if available, otherwise copy repository files
# In release workflow: dist/pencarimovie-downloader-linux-${TARGETARCH}.tar.gz
# When TARGETARCH=amd64 -> linux-x86_64; TARGETARCH=arm64 -> linux-aarch64
COPY . /tmp/repo/

ARG UPSTREAM_REPO=aiskendi/pencarimovie-server
ARG UPSTREAM_TAG=latest

RUN set -e; \
    ARCH_SUFFIX=""; \
    if [ "$TARGETARCH" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then \
        ARCH_SUFFIX="linux-aarch64"; \
    else \
        ARCH_SUFFIX="linux-x86_64"; \
    fi; \
    mkdir -p /tmp/extract; \
    echo "Downloading upstream runtime from ${UPSTREAM_REPO} (${UPSTREAM_TAG})..."; \
    if [ "$UPSTREAM_TAG" = "latest" ]; then \
        curl -fsSL -o /tmp/server.tar.gz "https://github.com/${UPSTREAM_REPO}/releases/latest/download/pencarimovie-downloader-${ARCH_SUFFIX}.tar.gz" || \
        curl -fsSL -o /tmp/server.tar.gz "https://github.com/${UPSTREAM_REPO}/releases/latest/download/pencarimovie-server.tar.gz"; \
    else \
        curl -fsSL -o /tmp/server.tar.gz "https://github.com/${UPSTREAM_REPO}/releases/download/${UPSTREAM_TAG}/pencarimovie-downloader-${ARCH_SUFFIX}.tar.gz" || \
        curl -fsSL -o /tmp/server.tar.gz "https://github.com/${UPSTREAM_REPO}/releases/download/${UPSTREAM_TAG}/pencarimovie-server.tar.gz"; \
    fi; \
    tar -xzf /tmp/server.tar.gz --strip-components=1 -C /tmp/extract; \
    rm -f /tmp/server.tar.gz; \
    test -f /tmp/extract/backend.php; \
    echo "Overlaying repository-owned UI only..."; \
    rm -rf /tmp/extract/public; \
    cp -r /tmp/repo/public /tmp/extract/public; \
    cp -a /tmp/extract/. /app/; \
    rm -rf /tmp/extract /tmp/repo; \
    mkdir -p /app/storage; \
    chmod -R 777 /app/storage; \
    chmod +x /app/bin/frankenphp /app/bin/php /app/bin/ffmpeg 2>/dev/null || true; \
    test -x /app/bin/frankenphp || (echo "FATAL: upstream /app/bin/frankenphp is missing or not executable!" && exit 1)

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV PATH="/app/bin:$PATH"
ENV PHP_BINDIR="/app/bin"
ENV PHPRC="/app/bin"

EXPOSE 8088

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["start"]
