# Bootstrap contract — `THDQD/zeroclaw-la-fork` images

This document describes what the LifeAtlas-flavored `zeroclaw` docker image expects from its container host (typically `claw-auth-proxy`).

## Image references

- Pinned per release: `ghcr.io/thdqd/zeroclaw-la-fork:v<base>-la.<MAJOR>.<MINOR>` (e.g., `:v0.7.3-la.1.1`).
- Floating: `ghcr.io/thdqd/zeroclaw-la-fork:latest` (always points at the most recent release; **do not use** for production fleet, pin instead).

## Container expectations

### Volumes

The image expects `/zeroclaw-data` to be a volume mount. Without this, all state (workspace, memory, sessions, config) is lost on container recreation. The `/zeroclaw-data` directory must contain (or be writable to create):

- `/zeroclaw-data/.zeroclaw/config.toml` — runtime configuration (the image ships a sensible default; the proxy should overlay user-specific values via env-var overrides or a mounted file).
- `/zeroclaw-data/workspace/` — agent workspace.
- `/zeroclaw-data/web/dist/` — web dashboard assets (baked in by the image build; can be left as-is).

### Environment variables

The image is sensitive to the standard `ZEROCLAW_*` env vars (see `crates/zeroclaw-config/src/schema.rs`). Notably for LifeAtlas:

- `ZEROCLAW_CHANNELS_LIFEATLAS_ENABLED=true`
- `ZEROCLAW_CHANNELS_LIFEATLAS_WEBHOOK_URL=http://proxy:8000/zeroclaw/push`
- `ZEROCLAW_CHANNELS_LIFEATLAS_AUTH_TOKEN=<bearer-token>`

The proxy provisions these per-container.

### Network

- Inbound: `/ws/chat` and the gateway's HTTP API on port 42617 (default).
- Outbound: HTTPS to `api.github.com` (for `zeroclaw update`) and to whatever LLM provider is configured.

## Bootstrap flow (one-time per container)

For each existing upstream-shaped container being migrated:

1. Stop the container.
2. Recreate from `ghcr.io/thdqd/zeroclaw-la-fork:v<pinned-tag>` with the same `/zeroclaw-data` volume.
3. Start. The patched binary now queries `https://api.github.com/repos/THDQD/zeroclaw-la-fork/releases/latest` for future updates.
4. Validate: `docker exec <container> zeroclaw --version` shows the LA suffix; the LifeAtlas channel functions end-to-end with the proxy webhook.

## Steady state

After bootstrap, containers self-update via `zeroclaw update` against the fork's GitHub releases. No further proxy involvement is needed for binary updates. The web dashboard (`web/dist`) is only refreshed when the container is recreated from a newer image.

## Pinning policy

Pin to a specific tag for production. Do not use `:latest`. A bad release published to `:latest` would otherwise propagate to every fresh container.
