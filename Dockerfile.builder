# Pinned builder image used by scripts/release-fork.sh and
# scripts/sync-from-upstream.sh. Provides the exact toolchain the
# release pipeline expects, independent of the maintainer's host setup.
FROM rust:1.93-bookworm

# Node 22 for `web/` build (matches upstream CI's node-version: 22).
# Use NodeSource's deb to avoid Debian's older default.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends \
        nodejs \
        pkg-config \
        libssl-dev \
        git \
 && rm -rf /var/lib/apt/lists/*

# Verify toolchains at image-build time so a broken image fails early.
RUN cargo --version && rustc --version && node --version && npm --version

WORKDIR /work

# Default no-op so scripts can override with `docker run ... cargo <cmd>`.
CMD ["cargo", "--version"]
