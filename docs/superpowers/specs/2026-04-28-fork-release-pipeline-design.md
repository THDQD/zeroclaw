# LifeAtlas Fork Release Pipeline — Spec

## Problem

The LifeAtlas project runs `zeroclaw` as its assistant, with each user's instance managed by `claw-auth-proxy`. We've started carrying patches on a fork (`THDQD/zeroclaw-la-fork`) — currently the v2 LifeAtlas channel and a Dockerfile.debian fix — and need a sustainable way to ship those patches to deployed containers.

The constraint is to reuse the existing `zeroclaw update` CLI as the in-container update mechanism, so containers self-update from our fork's releases on a roughly-weekly cadence. That mechanism today (`src/commands/update.rs`) hardcodes the upstream releases URL and uses a naive `Vec<u32>` version comparator that won't parse semver pre-release suffixes — both must be addressed for a fork-flavored release line to work.

A secondary constraint is operational: a previous account suspension on this fork was caused by pushing a sync of upstream commits whose push-triggered workflows fired on the fork. The release pipeline must avoid recreating that failure mode.

## Solution

A **two-branch fork model** combined with **off-GitHub-Actions builds** triggered by a pair of scripts on the maintainer's dev machine. The patched binary points at the fork's GitHub releases via a `option_env!`-driven compile-time URL override; the fork has its own version line `<upstream-base>-la.<MAJOR>.<MINOR>` that's independent of upstream's cadence; releases are produced by a Docker-pinned local build and published via `gh release create` plus a GHCR docker image push. GitHub Actions are disabled at the repo level on the fork as a failsafe against upstream workflows triggering during sync.

Bootstrap from currently-running upstream-shaped containers is a one-time `claw-auth-proxy`-side image swap; thereafter every container self-updates via `zeroclaw update` against the fork's releases.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                  upstream/master (zeroclaw-labs)                    │
│                  authoritative, untouched by us                     │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ git fetch upstream master (weekly)
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  origin/master  (THDQD/zeroclaw-la-fork)                            │
│  pure mirror of upstream/master, FF-only, never carries our diff    │
│  Actions DISABLED at repo level                                     │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ git merge master (into lifeatlas-master)
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  origin/lifeatlas-master  ← release source of truth                 │
│  upstream + small permanent diff:                                   │
│   • src/commands/update.rs: option_env! patch                       │
│   • src/commands/update.rs: semver-crate version comparator         │
│   • crates/zeroclaw-channels/src/lifeatlas.rs (already there)       │
│   • Cargo.toml: version = "<upstream-base>-la.M.N"                  │
│   • scripts/sync-from-upstream.sh, scripts/release-fork.sh          │
│   • Dockerfile.builder (pinned rust toolchain)                      │
│   • upstream's .github/workflows/* mostly DELETED                   │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ scripts/release-fork.sh
                           │   1. cargo test in pinned docker
                           │   2. cargo build (with ZEROCLAW_UPDATE_REPO env)
                           │   3. tar + sha256sum
                           │   4. git tag + push
                           │   5. gh release create
                           │   6. docker build + push GHCR
                           ▼
┌──────────────────────────────────┐    ┌──────────────────────────────┐
│  GitHub Releases (fork)          │    │  GHCR                        │
│  zeroclaw-x86_64-...la.M.N.tar.gz│    │  ghcr.io/thdqd/zeroclaw-     │
│  SHA256SUMS                      │    │   la-fork:v<base>-la.M.N     │
└──────────────┬───────────────────┘    │  ...:latest                  │
               │                        └──────────────┬───────────────┘
               │ HTTPS GET                             │ docker pull
               ▼                                       ▼
┌─────────────────────────────────┐  ┌──────────────────────────────────┐
│  zeroclaw update (in-container) │  │  bootstrap: claw-auth-proxy      │
│  patched binary queries         │  │  pulls fresh image with patched  │
│  api.github.com/repos/THDQD/    │  │  binary baked in (one-time per   │
│  zeroclaw-la-fork/releases      │  │  container)                      │
│  via option_env!                │  └──────────────────────────────────┘
└─────────────────────────────────┘
```

Two paths get binaries onto containers:

1. **Bootstrap (one-time per container)** — proxy pulls new image from GHCR. Used when transitioning a container from upstream-shaped image to LifeAtlas-shaped image, and for any freshly-created container.
2. **Steady state** — running container periodically calls `zeroclaw update`, hits the fork's GH releases, swaps its binary in place via the existing 6-phase pipeline.

## Versioning

Fork release versions are `<upstream-base>-la.<MAJOR>.<MINOR>`, valid semver pre-release strings. Examples: `0.7.3-la.1.1`, `0.7.4-la.2.5`.

### Bump rules

- **MINOR** increments on every release.
- **MAJOR** is bumped manually at maintainer discretion (LA-internal epoch markers); MINOR resets to `1`.
- **Upstream base** tracks whatever upstream version is at the tip of `master` after the most recent successful merge into `lifeatlas-master`. Does not trigger a release on its own; updates as a side-effect of the next release.

### Why this scheme

- Decoupled from upstream cadence: the fork can release weekly even when upstream is silent.
- Informative: the version string carries the upstream base, useful for debugging "what did this binary inherit?".
- Sortable with the standard `semver` crate without custom comparator code (each pre-release identifier is purely numeric or purely alphanumeric, sorted natively).
- Two-number LA suffix (MAJOR.MINOR) gives a stable LA-internal identifier independent of upstream version.

### Source of truth

The latest fork tag (`git tag -l 'v*-la.*' --sort=-v:refname | head -1`) is the source of truth for the next release's MAJOR.MINOR. No state file. The release script parses the latest tag and increments accordingly.

## Branch model

The fork uses two long-lived branches on `origin`:

- `master` — pure mirror of `upstream/master`, fast-forward only, never carries our patches. Synced via either GitHub's "Sync fork" button or `scripts/sync-from-upstream.sh`.
- `lifeatlas-master` — release source of truth. Carries the permanent fork diff plus the upstream history merged in weekly. This is the branch Cargo.toml's `-la.M.N` version lives on, and the branch every release tag points at.

`master` exists primarily to make merges cleanly attributable ("this came from upstream") and to keep the upstream lineage untouched by our edits.

## Permanent source diff on `lifeatlas-master`

### `src/commands/update.rs` — endpoint redirect

Replace the two hardcoded URL constants with `option_env!`-driven helpers:

```rust
const DEFAULT_UPDATE_REPO: &str = "zeroclaw-labs/zeroclaw";

fn update_repo() -> &'static str {
    option_env!("ZEROCLAW_UPDATE_REPO").unwrap_or(DEFAULT_UPDATE_REPO)
}

fn releases_latest_url() -> String {
    format!("https://api.github.com/repos/{}/releases/latest", update_repo())
}

fn releases_tag_url() -> String {
    format!("https://api.github.com/repos/{}/releases/tags", update_repo())
}
```

The two `let url = match target_version { ... }` arms in `check()` are updated to call these helpers. At fork build time, `ZEROCLAW_UPDATE_REPO=THDQD/zeroclaw-la-fork` is set in the cargo environment so the binary embeds the fork's URL. Upstream builds, with the env var unset, retain the upstream URL.

This patch is **upstream-PR-able** as a quality-of-life feature — if accepted, the fork's permanent diff shrinks by one of its largest items.

### `src/commands/update.rs` — semver-aware comparator

Replace the existing `version_is_newer`:

```rust
fn version_is_newer(current: &str, candidate: &str) -> bool {
    use semver::Version;
    match (Version::parse(current), Version::parse(candidate)) {
        (Ok(c), Ok(n)) => n > c,
        _ => false,
    }
}
```

Add `semver = "1"` to the workspace's direct dependencies. This patch is also **upstream-PR-able**.

### `Cargo.toml` — version suffix

`[workspace.package].version` and matching internal-crate version pins use the `<base>-la.M.N` form. Each release script invocation bumps it.

### Operational files

New on `lifeatlas-master`:

- `scripts/sync-from-upstream.sh`
- `scripts/release-fork.sh`
- `Dockerfile.builder` — pinned `rust:1.93-bookworm` builder used by both scripts
- `docs/BOOTSTRAP.md` (optional) — proxy↔image contract documentation

### Workflow files

The fork's GitHub Actions are disabled at repo level. As a defense-in-depth measure, all upstream workflow files that have `push:` triggers (or that perform release-related actions) are deleted from `lifeatlas-master`. Specifically:

**Deleted from `lifeatlas-master`**: `release-stable-manual.yml`, `daily-audit.yml`, `discord-release.yml`, `pub-aur.yml`, `pub-homebrew-core.yml`, `pub-scoop.yml`, `sync-marketplace-templates.yml`, `tweet-release.yml`, `cross-platform-build-manual.yml`.

**Kept**: `ci.yml`, `pr-path-labeler.yml`. Both run on PRs only and are harmless on a fork that doesn't accept PRs.

If a future upstream sync introduces a new workflow file, the audit phase of `sync-from-upstream.sh` halts and requires explicit acknowledgment.

## Sync workflow — `scripts/sync-from-upstream.sh`

Brings the fork up to date with upstream master and prepares `lifeatlas-master` for release. Halts on any unresolved conflict.

### Phases

1. **Preflight** — clean tree; correct origin/upstream remotes; not on a tag awaiting release.
2. **Fetch** — `git fetch upstream master --no-tags` and `git fetch origin --no-tags`.
3. **Fast-forward `master` mirror** — handles four cases:
   - All three (local/origin/upstream) equal → already in sync, skip.
   - Local behind, origin already at upstream (e.g., GitHub "Sync fork" button used) → FF local, no push.
   - Local and origin both behind → FF local, push to origin.
   - Local ahead of upstream → divergence, refuse and exit `40 master_diverged`.
4. **Workflow audit** — diff `.github/workflows/` between old and new `master` tip. If any file changed, exit `20 workflow_changes_detected` requiring `--ack-workflow-changes` to proceed on rerun.
5. **Merge `master` into `lifeatlas-master`** — `git merge master`. On conflict, leave repo in mid-merge state and exit `10 merge_conflict`. On clean merge, continue.
6. **Cargo.toml base-version reconciliation** — if upstream base advanced (e.g., `0.7.3` → `0.7.4`), set `lifeatlas-master`'s `[workspace.package].version` to `<new-base>-la.<MAJOR>.<MINOR>` preserving the prior MAJOR.MINOR. Commit as a fixup. (Release script handles the next bump.)
7. **Sanity check** — `cargo check --all-targets --locked`. On failure, exit `30 cargo_check_failed`.
8. **Report** — print `git log master..lifeatlas-master --oneline` (our remaining patches) and `git log <prev-master-tip>..master --oneline` (upstream changes pulled in). Exit `0`, `STATUS: ready_to_release`.

### Idempotency

Each phase has a "is this already done?" check. Re-running after any failure resumes from the right phase: mid-merge detected via `git rev-parse -q --verify MERGE_HEAD`; version reconciled detected by parsing Cargo.toml against current upstream base.

### What the script does NOT do

- Push `lifeatlas-master` (release script's job).
- Run the full test suite (release script's job).
- Tag (release script's job).
- Auto-resolve workflow file additions (escalates to human).

## Release workflow — `scripts/release-fork.sh`

Produces one fork release. Assumes `sync-from-upstream.sh` exited `0`.

### Phases

1. **Preflight** — on `lifeatlas-master`, clean tree, required tools available (`cargo`, `docker`, `gh`, `jq`, `tar`, `sha256sum`), `gh auth status` OK, `lifeatlas-master >= master`, target tag doesn't exist, fork's repo-level Actions are confirmed disabled (`gh api /repos/THDQD/zeroclaw-la-fork/actions/permissions --jq '.enabled'` returns `false`).
2. **Compute new version** — parse current Cargo.toml version. If `--bump-major`: `MAJOR += 1`, `MINOR = 1`. Else: `MINOR += 1`. New version is `<base>-la.<MAJOR>.<MINOR>`.
3. **Bump version in repo** — update `[workspace.package].version` and matching internal-crate version pins; `cargo check --workspace --locked` to refresh `Cargo.lock`. Commit `chore(release): v<new-version>`.
4. **Run tests in pinned builder image** — `docker run --rm -v "$PWD:/work" -w /work zeroclaw-builder:rust1.93 cargo test --workspace --release --locked` (skipping `--test live`). On failure: `git reset --hard HEAD^`, exit `30 cargo_test_failed`.
5. **Build release binary** — same builder image with `ZEROCLAW_UPDATE_REPO=THDQD/zeroclaw-la-fork` set: `cargo build --release --target x86_64-unknown-linux-gnu --locked --features "<LIFEATLAS_RELEASE_FEATURES>"`. Verify the resulting binary's `--version` matches and that `strings target/.../zeroclaw | grep -F 'THDQD/zeroclaw-la-fork'` succeeds. If the env var didn't propagate, fail.
6. **Build web dashboard** — `cd web && npm ci && npm run build` using node 22 (matching upstream CI). Either via a node:22 docker container or natively if the dev box has node 22 pinned.
7. **Package tarball** — `tar czf zeroclaw-x86_64-unknown-linux-gnu.tar.gz` with the binary and `web/dist/`. Filename must contain the literal `x86_64-unknown-linux-gnu` (substring match in `find_asset_url`). Generate `SHA256SUMS`.
8. **Generate release notes** — if `CHANGELOG-next.md` exists in repo root, use it. Else extract `feat(...)` commits from `git log <prev-tag>..HEAD --no-merges`. Write to `release-notes.md` (gitignored).
9. **Tag and push** — `git tag -a v<new-version>`, `git push origin lifeatlas-master`, `git push origin v<new-version>`. Pushes are separate (not `--follow-tags`) so failures are observable mid-flight.
10. **`gh release create`** — `gh release create v<new-version> zeroclaw-x86_64-unknown-linux-gnu.tar.gz SHA256SUMS --repo THDQD/zeroclaw-la-fork --title "v<new-version>" --notes-file release-notes.md --latest`.
11. **Build + push docker image** — `docker build -f Dockerfile.ci -t ghcr.io/thdqd/zeroclaw-la-fork:v<new-version> -t ghcr.io/thdqd/zeroclaw-la-fork:latest .`. `docker push --all-tags ghcr.io/thdqd/zeroclaw-la-fork`. Auth via `gh auth token | docker login ghcr.io -u thdqd --password-stdin`. **GHCR namespace must be lowercase**: although the GitHub user is `THDQD`, the GHCR path is `ghcr.io/thdqd/...` — the script normalizes this.
12. **Smoke verification** — `docker run --rm ghcr.io/thdqd/zeroclaw-la-fork:v<new-version> --version` matches new version; `gh api /repos/THDQD/zeroclaw-la-fork/releases/latest --jq '.tag_name'` equals `v<new-version>`.
13. **Report** — `STATUS: released`. Print release URL, image tag, version, asset checksum.

### `LIFEATLAS_RELEASE_FEATURES`

A constant in the script defining the cargo feature set for fork builds. The exact set is **finalized during implementation** based on what the proxy and LifeAtlas channel actually require — likely a subset of upstream's `channel-matrix,channel-lark,whatsapp-web` (drop the ones LifeAtlas doesn't use) plus whatever feature flags gate the LifeAtlas channel. Tunable per-invocation via `--features <list>`.

### Recovery semantics

Each phase is idempotent on re-run: tag-existence, release-existence, and image-manifest-existence checks let the script resume after partial failure. Pre-tag failures are recoverable via `git reset --hard HEAD^`. Post-tag failures (release exists but image push failed, etc.) just need a re-run.

## Agent + human friendliness

Both scripts follow the same conventions so they're equally usable by maintainers and by coding agents driving them:

- All progress to **stderr** with `[phase N/M] <name>` headers.
- A single `STATUS: <state>` line on **stdout** at exit. Trivially parsable.
- Stable exit codes:
  - `0` — success
  - `10` — merge conflict, human resolution required
  - `20` — workflow changes detected, re-run with `--ack-workflow-changes`
  - `30` — cargo check/test failed
  - `40` — precondition failure
  - `1` — uncategorized
- Flags: `--dry-run`, `--status`, `--ack-workflow-changes`, `--bump-major` (release script only), `--features` (release script only), `--help`.
- No interactive prompts by default; `--interactive` available but optional.
- Idempotent: re-running after partial failure resumes from the right phase.

## Bootstrap path

Bootstrap is a one-time per-container transition from upstream-shaped binary to fork-shaped binary. The upstream binary cannot self-bootstrap — its `option_env!` was unset at build time, so it queries upstream releases and never sees the fork. Bootstrap must come from outside the container.

### Mechanism

This is a **`claw-auth-proxy`-side operation**. The proxy's container provisioning logic is updated to pull `ghcr.io/thdqd/zeroclaw-la-fork:<pinned-tag>` (not `:latest`) for new and existing containers. Existing containers are recreated against the new image; data persists via the existing `/zeroclaw-data` volume mount.

### Rollout sequencing

- Pin a known-good fork tag before any bootstrap.
- Pilot one container; validate `zeroclaw --version` shows the LA suffix, `zeroclaw update --check` queries the fork's repo, user data is intact, LifeAtlas channel is functional end-to-end.
- Wave the rest in batches.
- Mixed fleet (some upstream, some fork) is functional during transition; both halves keep self-updating from their respective release lines without cross-contamination.

### Out of scope for this fork

The bootstrap script itself lives in `claw-auth-proxy`. The fork's deliverable is the GHCR image; the proxy decides when and how to roll it out.

## Failure modes & rollback

### Per-container update failure (existing infrastructure)

The 6-phase update pipeline in `src/commands/update.rs` already handles binary failures: backup → swap → smoke test (`--version`) → rollback. A binary that fails to launch never replaces the running one. For binaries that boot but break in actual use, recovery is `zeroclaw update --version v<prev-good>` — the existing CLI supports targeted-version updates.

### Release-time failures

- **`option_env!` didn't propagate** — Phase 5 verification (`strings | grep`) catches this; no release ships. Without this check, a release could silently query upstream's URL and effectively un-bootstrap containers over time.
- **Bad release reached GitHub** — don't delete (containers may have already pulled it; deletion creates a "what version is this?" mystery). Ship `+1` MINOR (or `--bump-major` if severe) and mark the bad release as `--prerelease` via `gh release edit`. Containers skip it on next update check.

### Sync-time failures

- **Workflow file slipped through** — Phase 4 of sync script audits and refuses; failsafe is repo-level Actions disabled. Both must fail for the suspension scenario to recur.
- **Patch set diverging over time** — track `git diff master..lifeatlas-master --stat` size as a soft metric. Pursue upstream PRs for the obvious candidates (`option_env!` redirect, semver comparator, Dockerfile.debian fix).

### Catastrophic rollback

Pin the proxy's deploy config to a prior-known-good image tag and re-bootstrap the fleet onto it. Investigate the bad release in `lifeatlas-master`'s history; revert or fix-forward; ship next release.

### Web/dist limitation

`zeroclaw update` swaps only the binary. The web dashboard (`web/dist`) on a running container comes from the docker image at container creation. Fresh dashboard assets reach a container only via image-replacement (bootstrap path or container restart pulling a fresh image). Mention in release notes when relevant.

## File map

| File | Action | What |
|------|--------|------|
| `src/commands/update.rs` | Modify | `option_env!` redirect helpers; replace `version_is_newer` with `semver::Version` comparator |
| `Cargo.toml` (workspace) | Modify | Add `semver = "1"` direct dep; set `[workspace.package].version` to `<base>-la.M.N`; matching internal crate version pins |
| `scripts/sync-from-upstream.sh` | Create | Sync workflow per Sync section above |
| `scripts/release-fork.sh` | Create | Release workflow per Release section above |
| `Dockerfile.builder` | Create | Pinned `rust:1.93-bookworm` builder image |
| `.github/workflows/release-stable-manual.yml` | Delete on `lifeatlas-master` | Replaced by `release-fork.sh` |
| `.github/workflows/daily-audit.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/discord-release.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/pub-aur.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/pub-homebrew-core.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/pub-scoop.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/sync-marketplace-templates.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/tweet-release.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/cross-platform-build-manual.yml` | Delete on `lifeatlas-master` | Not needed |
| `.github/workflows/ci.yml` | Keep | Runs on PRs only |
| `.github/workflows/pr-path-labeler.yml` | Keep | Runs on PRs only |
| `docs/BOOTSTRAP.md` | Create (optional) | Proxy↔image contract documentation |

### First-time setup (one-time, before first release)

GitHub repository configuration (web UI or `gh api`):
- Settings → Actions → General → **Disable actions** (failsafe).
- Optional: switch default branch to `lifeatlas-master`.

Maintainer dev-machine configuration:
- `gh auth login` with token scopes including `repo` and `write:packages` (the latter is needed for GHCR pushes).
- `gh auth token | docker login ghcr.io -u thdqd --password-stdin` to seed docker's GHCR credentials. The release script re-runs this if the docker daemon's auth has expired.
- `docker buildx` available (standard on modern Docker Engine; no extra install on most distros).
- Build the `Dockerfile.builder` image once: `docker build -f Dockerfile.builder -t zeroclaw-builder:rust1.93 .`. Subsequent runs reuse the cached image; rebuild only when `Dockerfile.builder` changes.

### No upstream changes required

The design works with upstream as-is. Two patches (`option_env!` redirect, `semver` comparator) are PR-able upstream and would shrink the permanent fork diff if accepted. Pursue opportunistically; do not block on them.

## Design decisions

| Decision | Rationale | Alternative considered |
|----------|-----------|----------------------|
| Audience: proxy-managed containers (steady) + one-time docker image swap (bootstrap) | Matches actual deployment topology. The upstream binary cannot self-bootstrap because its URL is compile-time-baked. | End-user installs (B) — not the actual audience. Image-only with no `zeroclaw update` (D-only) — would mean rebuilding+redeploying every container weekly, heavyweight |
| Endpoint redirect via `option_env!` compile-time override | Tiny source diff; no runtime config burden on each container; PR-able upstream | Hardcoded fork URL — permanent merge-conflict surface. Runtime config — adds container provisioning surface area for no benefit. Custom indirection server — unnecessary moving parts |
| Versioning: `<base>-la.<MAJOR>.<MINOR>` semver pre-release | Valid semver; numeric sub-identifiers compare correctly under `semver` crate; carries upstream base for debuggability; LA version line decoupled from upstream cadence | Single counter `-la.N` — loses LA-internal epoch information. `0.7.3+la.N` build metadata — semver ignores build metadata for ordering, requires custom comparator. Date-based — loses link to upstream version |
| MINOR resets on MAJOR bump | Avoids triple-digit MINOR; semver still orders correctly because MAJOR comparison settles before MINOR | MINOR globally monotonic — eventually unsightly |
| Two-branch model (`master` mirror + `lifeatlas-master` release source) | Clean separation; upstream lineage never touched; merge attribution clear | Single-branch rebase — force-push to release branch. Single-branch merge — works but conflates lineages |
| Build outside GitHub Actions; `gh release create` from dev machine | Eliminates upstream-workflow trigger surface; avoids account suspension recurrence; trivial pipeline for one target | Allow-listed Actions on fork — adds re-audit burden every upstream sync. Repo-guarded workflows on fork — perpetual diff surface |
| Targets: linux x86_64 only | Matches actual deployment audience (containers); minimal pipeline | Full upstream matrix — wasted build time, signing complexity for unused targets |
| Two scripts (sync + release), not one mega-script | Conflict resolution is a human-in-the-loop step; clear separation between merging risk and release ceremony | One script with phased pause — works but mixes merge-state recovery with release recovery. Cron automation — risks releasing during conflicts |
| Build inside pinned Docker image on dev machine | Reproducibility without dedicated builder host; same patterns work for human and agent invocation | Native build — toolchain drift across maintainers. Self-hosted runner — overkill at this scale |
| Push docker image to GHCR per release | Required for bootstrap path; matches upstream pattern; same image is reused for fresh containers | Tarball-only — fragile, every fresh container needs to do its own update dance |
| GitHub Actions disabled at repo level + workflow files deleted | Belt-and-suspenders against re-suspension; clear that the fork is operationally distinct | Either alone — single-failure-mode. Repo-guards — perpetual conflict surface |
| Stable exit codes + `STATUS:` stdout line | Same scripts usable by humans and coding agents | Free-form output — agents must regex-scrape, fragile |
