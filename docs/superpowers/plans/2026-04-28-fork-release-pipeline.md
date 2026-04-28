# LifeAtlas Fork Release Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the source patches and operational scripts that let `THDQD/zeroclaw-la-fork` ship its own GitHub releases consumed by `zeroclaw update` in proxy-managed containers.

**Architecture:** Two-branch fork with `master` mirroring upstream and `lifeatlas-master` carrying patches. Patched binary embeds a fork-specific GitHub releases URL via `option_env!` at compile time. Releases are produced off-GHA by two scripts on the maintainer's dev machine (one for upstream sync, one for build+publish). Versioning: `<upstream-base>-la.<MAJOR>.<MINOR>` semver pre-release, ordered by the `semver` crate.

**Tech Stack:** Rust (binary patches + tests), Bash (sync + release scripts), Docker (pinned builder image), `gh` CLI (GitHub releases), GHCR (docker registry).

**Spec:** `docs/superpowers/specs/2026-04-28-fork-release-pipeline-design.md`

**Working branch:** `lifeatlas-channel-v3` (the eventual `lifeatlas-master`).

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/commands/update.rs` | **Modify** | `option_env!`-driven URL helpers; `semver`-based `version_is_newer` |
| `Cargo.toml` (workspace) | **Modify** | Add `semver = "1"` direct dep; bump `[workspace.package].version` and 14 internal crate pins to `0.7.3-la.1.0` |
| `Dockerfile.builder` | **Create** | Pinned `rust:1.93-bookworm` + node 22; reproducible local builds |
| `scripts/sync-from-upstream.sh` | **Create** | Phase-driven sync: fetch → FF master → audit workflows → merge to `lifeatlas-master` → reconcile Cargo.toml base version → `cargo check` |
| `scripts/release-fork.sh` | **Create** | Phase-driven release: bump → test → build → package → tag → `gh release create` → docker build/push → smoke verify |
| `.github/workflows/release-stable-manual.yml` | **Delete** | Replaced by release-fork.sh |
| `.github/workflows/daily-audit.yml` | **Delete** | Not needed on fork |
| `.github/workflows/discord-release.yml` | **Delete** | Not needed on fork |
| `.github/workflows/pub-aur.yml` | **Delete** | Not needed on fork |
| `.github/workflows/pub-homebrew-core.yml` | **Delete** | Not needed on fork |
| `.github/workflows/pub-scoop.yml` | **Delete** | Not needed on fork |
| `.github/workflows/sync-marketplace-templates.yml` | **Delete** | Not needed on fork |
| `.github/workflows/tweet-release.yml` | **Delete** | Not needed on fork |
| `.github/workflows/cross-platform-build-manual.yml` | **Delete** | Not needed on fork |

Files kept as-is: `.github/workflows/ci.yml`, `.github/workflows/pr-path-labeler.yml` (PR-only triggers, harmless).

---

## Task 1: `option_env!` URL redirect in `update.rs`

**Files:**
- Modify: `src/commands/update.rs:7-10` (URL constants), `src/commands/update.rs:31-41` (URL construction in `check()`)
- Test: `src/commands/update.rs` `#[cfg(test)] mod tests` block (existing, append new tests)

**Why:** The patched binary must point at the fork's releases. `option_env!("ZEROCLAW_UPDATE_REPO")` lets the build environment override the URL at compile time without any runtime configuration. Default unset → upstream URL (so this is also upstream-PR-able).

- [ ] **Step 1: Add a failing test for `update_repo()` returning the default**

In `src/commands/update.rs`, inside the existing `#[cfg(test)] mod tests { ... }` block (around line 410), add:

```rust
    #[test]
    fn update_repo_returns_default_when_env_unset() {
        // option_env! is evaluated at compile time. In `cargo test` runs,
        // ZEROCLAW_UPDATE_REPO is unset by default, so the helper returns
        // the upstream default. This guards against accidental hardcoding.
        assert_eq!(update_repo(), "zeroclaw-labs/zeroclaw");
    }

    #[test]
    fn releases_latest_url_uses_update_repo() {
        let url = releases_latest_url();
        assert!(url.starts_with("https://api.github.com/repos/"));
        assert!(url.ends_with("/releases/latest"));
        assert!(url.contains(update_repo()));
    }

    #[test]
    fn releases_tag_url_uses_update_repo() {
        let url = releases_tag_url();
        assert!(url.starts_with("https://api.github.com/repos/"));
        assert!(url.ends_with("/releases/tags"));
        assert!(url.contains(update_repo()));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --lib commands::update::tests::update_repo 2>&1 | tail -20`
Expected: FAIL — `cannot find function 'update_repo' in this scope`.

- [ ] **Step 3: Replace the URL constants with helpers**

In `src/commands/update.rs`, replace lines 7-10 (the two `const ... = "https://api.github.com/repos/zeroclaw-labs/zeroclaw/..."` declarations) with:

```rust
const DEFAULT_UPDATE_REPO: &str = "zeroclaw-labs/zeroclaw";

fn update_repo() -> &'static str {
    option_env!("ZEROCLAW_UPDATE_REPO").unwrap_or(DEFAULT_UPDATE_REPO)
}

fn releases_latest_url() -> String {
    format!(
        "https://api.github.com/repos/{}/releases/latest",
        update_repo()
    )
}

fn releases_tag_url() -> String {
    format!(
        "https://api.github.com/repos/{}/releases/tags",
        update_repo()
    )
}
```

- [ ] **Step 4: Update the call sites in `check()`**

In `src/commands/update.rs`, find the block currently at lines 31-41:

```rust
    let url = match target_version {
        Some(v) => {
            let tag = if v.starts_with('v') {
                v.to_string()
            } else {
                format!("v{v}")
            };
            format!("{GITHUB_RELEASES_TAG_URL}/{tag}")
        }
        None => GITHUB_RELEASES_LATEST_URL.to_string(),
    };
```

Replace it with:

```rust
    let url = match target_version {
        Some(v) => {
            let tag = if v.starts_with('v') {
                v.to_string()
            } else {
                format!("v{v}")
            };
            format!("{}/{tag}", releases_tag_url())
        }
        None => releases_latest_url(),
    };
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test --lib commands::update::tests 2>&1 | tail -30`
Expected: all `update_repo*` and `releases_*_url*` tests PASS, plus the existing tests (`test_version_comparison`, `current_target_triple_is_not_empty`, `find_asset_url_*`, `detect_arch_*`, `host_architecture_is_known`, `extract_tar_gz_*`) continue to pass.

- [ ] **Step 6: Verify the binary still compiles**

Run: `cargo check 2>&1 | tail -10`
Expected: clean compile, no warnings or errors.

- [ ] **Step 7: Commit**

```bash
git add src/commands/update.rs
git commit -m "feat(update): support compile-time URL override via option_env!"
```

---

## Task 2: Semver-based `version_is_newer` comparator

**Files:**
- Modify: `Cargo.toml:65` (add `semver` to `[dependencies]`)
- Modify: `src/commands/update.rs:194-199` (replace `version_is_newer` body)
- Modify: `src/commands/update.rs:414-421` (extend `test_version_comparison`)

**Why:** The naive `Vec<u32>` comparator silently drops non-numeric chunks, so `0.7.3-la.1.0` parses to `[0, 7, 1, 0]` (the `"3-la"` fails u32 parse) and compares wrong. The fork's release versions are semver pre-releases; the comparator must use a real semver parser.

- [ ] **Step 1: Add `semver` to the binary crate's dependencies**

In `Cargo.toml`, find the `[dependencies]` section starting at line 65. Add `semver = "1"` alphabetically (next to `serde`-related entries or just appended — consistency with the surrounding ordering is fine). Example placement:

```toml
semver = "1"
```

- [ ] **Step 2: Verify the dep resolves**

Run: `cargo check --offline 2>&1 | head -10`
If offline check fails because `semver` isn't in the local cache:
Run: `cargo check 2>&1 | head -10`
Expected: compiles (semver is a tiny pure-rust crate with no surprises).

- [ ] **Step 3: Add failing tests for semver comparison**

In `src/commands/update.rs`, find the existing `fn test_version_comparison` (around line 414). Replace its body and add adjacent tests:

```rust
    #[test]
    fn test_version_comparison() {
        // Plain semver
        assert!(version_is_newer("0.4.3", "0.5.0"));
        assert!(version_is_newer("0.4.3", "0.4.4"));
        assert!(!version_is_newer("0.5.0", "0.4.3"));
        assert!(!version_is_newer("0.4.3", "0.4.3"));
        assert!(version_is_newer("1.0.0", "2.0.0"));
    }

    #[test]
    fn test_version_comparison_la_prerelease_minor_bump() {
        assert!(version_is_newer("0.7.3-la.1.1", "0.7.3-la.1.2"));
        assert!(!version_is_newer("0.7.3-la.1.2", "0.7.3-la.1.1"));
        assert!(!version_is_newer("0.7.3-la.1.5", "0.7.3-la.1.5"));
    }

    #[test]
    fn test_version_comparison_la_major_bump() {
        // MINOR resets to 1 on MAJOR bump; semver still orders correctly
        // because MAJOR tokens (numeric) are compared numerically before MINOR.
        assert!(version_is_newer("0.7.3-la.1.50", "0.7.3-la.2.1"));
        assert!(!version_is_newer("0.7.3-la.2.1", "0.7.3-la.1.50"));
    }

    #[test]
    fn test_version_comparison_la_minor_double_digit() {
        // Numeric identifiers compare numerically (10 > 9), avoiding the
        // ASCII-lex pitfall that would say "la-10 < la-9".
        assert!(version_is_newer("0.7.3-la.1.9", "0.7.3-la.1.10"));
        assert!(!version_is_newer("0.7.3-la.1.10", "0.7.3-la.1.9"));
    }

    #[test]
    fn test_version_comparison_upstream_base_advances() {
        assert!(version_is_newer("0.7.3-la.2.5", "0.7.4-la.1.1"));
        assert!(!version_is_newer("0.7.4-la.1.1", "0.7.3-la.2.5"));
    }

    #[test]
    fn test_version_comparison_invalid_input_does_not_update() {
        // Garbage input must NOT trigger an update — fail closed.
        assert!(!version_is_newer("not-a-version", "0.7.3"));
        assert!(!version_is_newer("0.7.3", "garbage"));
        assert!(!version_is_newer("", ""));
    }
```

- [ ] **Step 4: Run tests to verify the new ones fail**

Run: `cargo test --lib commands::update::tests::test_version_comparison 2>&1 | tail -30`
Expected: the four new `test_version_comparison_la_*` and `test_version_comparison_invalid_input*` tests FAIL (existing comparator silently parses-and-truncates, producing wrong answers; original `test_version_comparison` may still pass on the simple cases). The original test should pass.

- [ ] **Step 5: Replace `version_is_newer` with the semver-based version**

In `src/commands/update.rs`, find lines 194-199:

```rust
fn version_is_newer(current: &str, candidate: &str) -> bool {
    let parse = |v: &str| -> Vec<u32> { v.split('.').filter_map(|p| p.parse().ok()).collect() };
    let cur = parse(current);
    let cand = parse(candidate);
    cand > cur
}
```

Replace with:

```rust
fn version_is_newer(current: &str, candidate: &str) -> bool {
    use semver::Version;
    match (Version::parse(current), Version::parse(candidate)) {
        (Ok(c), Ok(n)) => n > c,
        // Unparseable input is treated as "not newer" — fail closed,
        // never auto-update on garbage version strings.
        _ => false,
    }
}
```

- [ ] **Step 6: Run tests to verify all pass**

Run: `cargo test --lib commands::update::tests::test_version_comparison 2>&1 | tail -30`
Expected: all six `test_version_comparison*` tests PASS.

- [ ] **Step 7: Run the full update-module test suite**

Run: `cargo test --lib commands::update 2>&1 | tail -20`
Expected: every test in `commands::update::tests` passes (including the option_env tests from Task 1, and all existing tests).

- [ ] **Step 8: Commit**

```bash
git add Cargo.toml Cargo.lock src/commands/update.rs
git commit -m "feat(update): use semver crate for version comparison"
```

---

## Task 3: Bump workspace version to first LA suffix

**Files:**
- Modify: `Cargo.toml:6` (`[workspace.package].version`)
- Modify: `Cargo.toml:13-26` (14 internal crate version pins)

**Why:** The Cargo.toml version is the source of truth for what the next release will be. Set it to `0.7.3-la.1.0` so the first invocation of `release-fork.sh` (which bumps MINOR before tagging) produces tag `v0.7.3-la.1.1` per the spec example.

Cargo treats pre-release versions specially in version requirements: `version = "0.7.3"` does NOT match a `0.7.3-la.1.0` package, so every internal crate pin must be updated to match exactly.

- [ ] **Step 1: Bump `[workspace.package].version`**

In `Cargo.toml`, change line 6 from:

```toml
version = "0.7.3"
```

to:

```toml
version = "0.7.3-la.1.0"
```

- [ ] **Step 2: Bump all 14 internal crate pins**

In `Cargo.toml` lines 13-26, replace `version = "0.7.3"` with `version = "0.7.3-la.1.0"` in each of these entries (one per line):

```toml
zeroclaw-api = { path = "crates/zeroclaw-api", version = "0.7.3-la.1.0" }
zeroclaw-infra = { path = "crates/zeroclaw-infra", version = "0.7.3-la.1.0" }
zeroclaw-config = { path = "crates/zeroclaw-config", version = "0.7.3-la.1.0", default-features = false }
zeroclaw-providers = { path = "crates/zeroclaw-providers", version = "0.7.3-la.1.0" }
zeroclaw-memory = { path = "crates/zeroclaw-memory", version = "0.7.3-la.1.0" }
zeroclaw-channels = { path = "crates/zeroclaw-channels", version = "0.7.3-la.1.0", default-features = false }
zeroclaw-tools = { path = "crates/zeroclaw-tools", version = "0.7.3-la.1.0" }
zeroclaw-runtime = { path = "crates/zeroclaw-runtime", version = "0.7.3-la.1.0", default-features = false }
zeroclaw-tui = { path = "crates/zeroclaw-tui", version = "0.7.3-la.1.0" }
zeroclaw-plugins = { path = "crates/zeroclaw-plugins", version = "0.7.3-la.1.0" }
zeroclaw-gateway = { path = "crates/zeroclaw-gateway", version = "0.7.3-la.1.0" }
zeroclaw-hardware = { path = "crates/zeroclaw-hardware", version = "0.7.3-la.1.0" }
zeroclaw-tool-call-parser = { path = "crates/zeroclaw-tool-call-parser", version = "0.7.3-la.1.0" }
zeroclaw-macros = { path = "crates/zeroclaw-macros", version = "0.7.3-la.1.0" }
```

(`aardvark-sys = { path = "crates/aardvark-sys", version = "0.1.0" }` on line 27 is independently versioned — leave it alone.)

The simplest mechanical edit is a single sed:

```bash
sed -i 's/version = "0\.7\.3"/version = "0.7.3-la.1.0"/g' Cargo.toml
```

Then manually verify line 6 (`[workspace.package].version`) was bumped, and `aardvark-sys` on line 27 is still at `0.1.0`.

- [ ] **Step 3: Verify no stray `"0.7.3"` references remain in workspace deps**

Run: `grep -n 'version = "0.7.3"' Cargo.toml`
Expected: empty output (every match was replaced).

Run: `grep -n 'version = "0.7.3-la.1.0"' Cargo.toml | wc -l`
Expected: `15` (1 workspace package version + 14 internal pins).

- [ ] **Step 4: Refresh `Cargo.lock` and verify the workspace compiles**

Run: `cargo check --workspace --locked 2>&1 | tail -20`

If it errors with "the lock file ... needs to be updated", run instead:

```bash
cargo check --workspace
```

Then verify the lock was regenerated:

```bash
git diff --stat Cargo.lock
```

Expected: `Cargo.lock` shows ~30 lines changed (every workspace member crate version updated).

After this, `cargo check --workspace --locked` should pass clean.

- [ ] **Step 5: Run the binary's `--version` to confirm it reports the new version**

Run: `cargo run --bin zeroclaw --quiet -- --version 2>&1 | tail -3`
Expected output contains `0.7.3-la.1.0` (or matches whatever your `--version` formatter produces — the substring `la.1.0` must be present).

- [ ] **Step 6: Run the existing test suite to confirm no regressions**

Run: `cargo test --lib commands::update 2>&1 | tail -10`
Expected: all `commands::update` tests pass (the version comparator handles pre-release strings correctly per Task 2).

- [ ] **Step 7: Commit**

```bash
git add Cargo.toml Cargo.lock
git commit -m "chore(release): bump workspace to 0.7.3-la.1.0 (fork release line)"
```

---

## Task 4: `Dockerfile.builder`

**Files:**
- Create: `Dockerfile.builder`

**Why:** Both scripts run cargo and node inside the same pinned image so builds are reproducible across maintainer machines. Pinning to `rust:1.93-bookworm` matches upstream's CI toolchain (1.93.0 + glibc 2.35 baseline via Debian bookworm).

- [ ] **Step 1: Create `Dockerfile.builder`**

Create file `Dockerfile.builder` at the repo root with:

```dockerfile
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
```

- [ ] **Step 2: Build the image**

Run: `docker build -f Dockerfile.builder -t zeroclaw-builder:rust1.93 . 2>&1 | tail -20`
Expected: build completes, final layer reports node version `v22.x.x` and rust `1.93.0`.

- [ ] **Step 3: Smoke-test the image**

Run: `docker run --rm zeroclaw-builder:rust1.93 sh -c 'cargo --version && rustc --version && node --version'`
Expected output (versions may differ in patch level, but major.minor must match):
```
cargo 1.93.0 (...)
rustc 1.93.0 (...)
v22.x.x
```

- [ ] **Step 4: Verify cargo can compile in-tree inside the image**

Run: `docker run --rm -v "$PWD:/work" -w /work zeroclaw-builder:rust1.93 cargo check --workspace 2>&1 | tail -20`
Expected: compiles. (First run downloads and compiles dependencies — may take 5+ minutes.)

If you get errors about file ownership (Docker on Linux runs as root by default; cargo creates files as root), pass `-u "$(id -u):$(id -g)"`:

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work" -w /work zeroclaw-builder:rust1.93 cargo check --workspace
```

- [ ] **Step 5: Commit**

```bash
git add Dockerfile.builder
git commit -m "build: add Dockerfile.builder for reproducible local releases"
```

---

## Task 5: Delete fork-incompatible workflow files

**Files:**
- Delete: `.github/workflows/release-stable-manual.yml`
- Delete: `.github/workflows/daily-audit.yml`
- Delete: `.github/workflows/discord-release.yml`
- Delete: `.github/workflows/pub-aur.yml`
- Delete: `.github/workflows/pub-homebrew-core.yml`
- Delete: `.github/workflows/pub-scoop.yml`
- Delete: `.github/workflows/sync-marketplace-templates.yml`
- Delete: `.github/workflows/tweet-release.yml`
- Delete: `.github/workflows/cross-platform-build-manual.yml`

**Why:** Belt-and-suspenders against the fork-Actions failure mode that caused a prior account suspension. Repo-level Actions disable is the primary safeguard; deleting these files is the secondary safeguard (so even if Actions are accidentally re-enabled, there's nothing to fire). Files kept (`ci.yml`, `pr-path-labeler.yml`) are PR-only and harmless on a fork that doesn't accept PRs.

- [ ] **Step 1: Verify Actions are disabled at repo level (mandatory prerequisite)**

Run: `gh api /repos/THDQD/zeroclaw-la-fork/actions/permissions --jq '.enabled'`
Expected: `false`.

If it returns `true`, **stop**. Disable Actions via the GitHub web UI: Settings → Actions → General → "Disable actions" → save. Re-run the check until it returns `false` before proceeding.

If `gh` is not authenticated or returns a permission error, run `gh auth login` first; the token needs at least `repo` scope to read this endpoint.

- [ ] **Step 2: Confirm the workflows you're about to delete**

Run: `ls .github/workflows/*.yml`
Expected: shows the 11 `.yml` files in the dir (9 to delete, 2 to keep).

- [ ] **Step 3: Delete the nine workflow files**

```bash
git rm \
  .github/workflows/release-stable-manual.yml \
  .github/workflows/daily-audit.yml \
  .github/workflows/discord-release.yml \
  .github/workflows/pub-aur.yml \
  .github/workflows/pub-homebrew-core.yml \
  .github/workflows/pub-scoop.yml \
  .github/workflows/sync-marketplace-templates.yml \
  .github/workflows/tweet-release.yml \
  .github/workflows/cross-platform-build-manual.yml
```

- [ ] **Step 4: Verify only the keep-list remains**

Run: `ls .github/workflows/*.yml`
Expected exactly two files: `ci.yml` and `pr-path-labeler.yml`. (`master-branch-flow.md` and `README.md` may also be in the dir — they're documentation, leave them.)

- [ ] **Step 5: Commit**

```bash
git commit -m "chore(fork): remove upstream release workflows from lifeatlas-master"
```

---

## Task 6: `scripts/sync-from-upstream.sh`

**Files:**
- Create: `scripts/sync-from-upstream.sh`

**Why:** This script is the weekly entry point that brings the fork up to date with upstream master and prepares `lifeatlas-master` for release. It halts cleanly on conflicts so a human (or coding agent) can resolve them, and is idempotent so re-running after a partial failure resumes from the right phase.

The script is built up phase by phase. Each step adds a phase and verifies it works before moving on.

- [ ] **Step 1: Create the script skeleton with flag parsing and exit codes**

Create file `scripts/sync-from-upstream.sh`:

```bash
#!/usr/bin/env bash
# sync-from-upstream.sh — bring fork up to date with upstream master
# and prepare lifeatlas-master for release.
#
# Exit codes (stable contract; agents and humans both rely on these):
#   0   success, ready for release
#   10  merge conflict, human resolution required
#   20  workflow files changed in upstream sync
#   30  cargo check failed after merge
#   40  precondition failure
#   1   uncategorized error
#
# Output channels:
#   stderr — all human-readable progress with [phase N/M] headers
#   stdout — a single STATUS: <state> line at exit

set -euo pipefail

# Exit code constants (use `exit "$EX_<NAME>"`).
EX_OK=0
EX_MERGE_CONFLICT=10
EX_WORKFLOW_CHANGES=20
EX_CARGO_CHECK=30
EX_PRECONDITION=40

# Configuration: branches, remotes, and where workflow files live.
ORIGIN_REMOTE="origin"
UPSTREAM_REMOTE="upstream"
MASTER_BRANCH="master"
RELEASE_BRANCH="lifeatlas-master"
WORKFLOWS_DIR=".github/workflows"

# Flags.
DRY_RUN=0
STATUS_ONLY=0
ACK_WORKFLOW_CHANGES=0
INTERACTIVE=0

usage() {
    cat <<'USAGE'
sync-from-upstream.sh — sync fork master from upstream and prepare lifeatlas-master.

Usage: scripts/sync-from-upstream.sh [flags]

Flags:
  --dry-run               Print what each phase would do; make no changes.
  --status                Report current state and exit; no fetches or changes.
  --ack-workflow-changes  Proceed past the workflow-audit phase after a human
                          confirmed the diff is benign.
  --interactive           Re-enable optional confirmation prompts (off by default).
  --help                  Print this help.

Exit codes:
  0   ready_to_release / master_up_to_date
  10  merge_conflict (repo left mid-merge; resolve and re-run)
  20  workflow_changes_detected (re-run with --ack-workflow-changes)
  30  cargo_check_failed
  40  precondition_failure
USAGE
}

# Parse flags.
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --status) STATUS_ONLY=1 ;;
        --ack-workflow-changes) ACK_WORKFLOW_CHANGES=1 ;;
        --interactive) INTERACTIVE=1 ;;
        --help|-h) usage; exit "$EX_OK" ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit "$EX_PRECONDITION" ;;
    esac
    shift
done

# Helpers (all output to stderr; STATUS line goes to stdout via emit_status).
log() { echo "[sync-from-upstream] $*" >&2; }
phase() { echo "" >&2; echo "[phase $1/$2] $3" >&2; }
fail() {
    local code="$1"; shift
    echo "ERROR: $*" >&2
    emit_status "$1"
    exit "$code"
}
emit_status() { echo "STATUS: $1"; }

# Skeleton placeholder — will be filled by subsequent steps.
log "(skeleton — phases not yet wired)"
emit_status "skeleton"
exit "$EX_OK"
```

Make it executable:

```bash
chmod +x scripts/sync-from-upstream.sh
```

Test the skeleton:

```bash
scripts/sync-from-upstream.sh --help
```

Expected: usage prints, exit 0.

```bash
scripts/sync-from-upstream.sh
```

Expected: stderr shows `[sync-from-upstream] (skeleton — phases not yet wired)`, stdout shows `STATUS: skeleton`, exit 0.

- [ ] **Step 2: Implement Phase 1 (preflight) and Phase 2 (fetch)**

Replace the skeleton placeholder near the bottom (`log "(skeleton — phases not yet wired)" ...` through `exit "$EX_OK"`) with:

```bash
# ─── Phase 1: Preflight ─────────────────────────────────────────────────
phase 1 8 "preflight"

# Confirm we're inside a git repo with the expected remotes.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "not a git repository"
fi
if ! git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "remote '$ORIGIN_REMOTE' is not configured"
fi
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "remote '$UPSTREAM_REMOTE' is not configured"
fi

# Working tree must be clean (untracked files are OK; modified/staged are not).
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "$EX_PRECONDITION" "working tree has uncommitted changes; commit or stash first"
fi

# Detect mid-merge state — if present, skip phases 2-5 and resume at phase 6.
RESUMING_MID_MERGE=0
if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    log "detected mid-merge on $(git symbolic-ref --short HEAD) — resuming"
    RESUMING_MID_MERGE=1
fi

# --status: report state and exit.
if [ "$STATUS_ONLY" -eq 1 ]; then
    if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
        emit_status "mid_merge"
    else
        emit_status "clean"
    fi
    exit "$EX_OK"
fi

# ─── Phase 2: Fetch ─────────────────────────────────────────────────────
phase 2 8 "fetch"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: git fetch $UPSTREAM_REMOTE $MASTER_BRANCH --no-tags"
    log "(dry-run) would: git fetch $ORIGIN_REMOTE --no-tags"
elif [ "$RESUMING_MID_MERGE" -eq 0 ]; then
    git fetch "$UPSTREAM_REMOTE" "$MASTER_BRANCH" --no-tags
    git fetch "$ORIGIN_REMOTE" --no-tags
else
    log "skipping fetch (resuming mid-merge)"
fi

# Subsequent phases will be appended in later steps.
emit_status "phases_2_complete"
exit "$EX_OK"
```

Test:

```bash
scripts/sync-from-upstream.sh --status
```

Expected: `STATUS: clean` (assuming clean tree, no mid-merge).

```bash
scripts/sync-from-upstream.sh --dry-run 2>&1 | tail -10
```

Expected: stderr shows `[phase 1/8] preflight`, `[phase 2/8] fetch`, `(dry-run) would: git fetch ...`. Stdout shows `STATUS: phases_2_complete`.

- [ ] **Step 3: Implement Phase 3 (FF master mirror, four cases)**

Append before the trailing `emit_status "phases_2_complete"; exit "$EX_OK"`:

```bash

# ─── Phase 3: Fast-forward master mirror ────────────────────────────────
phase 3 8 "fast-forward master mirror"

if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
    log "skipping master FF (resuming mid-merge)"
else
    LOCAL_MASTER=$(git rev-parse "$MASTER_BRANCH")
    UPSTREAM_MASTER=$(git rev-parse "$UPSTREAM_REMOTE/$MASTER_BRANCH")
    ORIGIN_MASTER=$(git rev-parse "$ORIGIN_REMOTE/$MASTER_BRANCH")

    if [ "$LOCAL_MASTER" = "$UPSTREAM_MASTER" ] \
       && [ "$ORIGIN_MASTER" = "$UPSTREAM_MASTER" ]; then
        log "master is already in sync with upstream and origin"
    else
        # Detect divergence (local master ahead of upstream — should never happen).
        if ! git merge-base --is-ancestor "$LOCAL_MASTER" "$UPSTREAM_MASTER"; then
            fail "$EX_PRECONDITION" \
                "local $MASTER_BRANCH has commits upstream/$MASTER_BRANCH does not — investigate manually"
        fi

        # Fast-forward local master if behind.
        if [ "$LOCAL_MASTER" != "$UPSTREAM_MASTER" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "(dry-run) would: git checkout $MASTER_BRANCH && git merge --ff-only $UPSTREAM_REMOTE/$MASTER_BRANCH"
            else
                git checkout "$MASTER_BRANCH"
                git merge --ff-only "$UPSTREAM_REMOTE/$MASTER_BRANCH"
            fi
        fi

        # Push to origin only if origin/master is also behind.
        if [ "$ORIGIN_MASTER" != "$UPSTREAM_MASTER" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "(dry-run) would: git push $ORIGIN_REMOTE $MASTER_BRANCH"
            else
                git push "$ORIGIN_REMOTE" "$MASTER_BRANCH"
            fi
        else
            log "origin/$MASTER_BRANCH is already at upstream tip (e.g., GitHub Sync Fork was used) — skipping push"
        fi
    fi

    OLD_MASTER_TIP="$LOCAL_MASTER"  # remember for workflow audit
    NEW_MASTER_TIP=$(git rev-parse "$MASTER_BRANCH")
fi
```

Update the trailing exit lines so the final `emit_status "phases_2_complete"; exit "$EX_OK"` becomes:

```bash
emit_status "phases_3_complete"
exit "$EX_OK"
```

Test:

```bash
scripts/sync-from-upstream.sh --dry-run 2>&1 | tail -15
```

Expected: `[phase 3/8] fast-forward master mirror` appears with appropriate `(dry-run) would: ...` or "already in sync" log lines.

- [ ] **Step 4: Implement Phase 4 (workflow audit)**

Append before the trailing `emit_status "phases_3_complete"; exit "$EX_OK"`:

```bash

# ─── Phase 4: Workflow audit ────────────────────────────────────────────
phase 4 8 "workflow audit"

if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
    log "skipping workflow audit (resuming mid-merge)"
elif [ "$OLD_MASTER_TIP" = "$NEW_MASTER_TIP" ]; then
    log "no changes to master tip — workflow audit not needed"
else
    WORKFLOW_DIFF=$(git diff --name-only "$OLD_MASTER_TIP" "$NEW_MASTER_TIP" -- "$WORKFLOWS_DIR" || true)
    if [ -n "$WORKFLOW_DIFF" ]; then
        if [ "$ACK_WORKFLOW_CHANGES" -eq 1 ]; then
            log "workflow changes acknowledged via --ack-workflow-changes:"
            echo "$WORKFLOW_DIFF" | sed 's/^/  /' >&2
        else
            log "workflow files changed in upstream sync:"
            echo "$WORKFLOW_DIFF" | sed 's/^/  /' >&2
            log "audit these changes for new push-triggered triggers,"
            log "then re-run with --ack-workflow-changes to proceed."
            emit_status "workflow_changes_detected"
            exit "$EX_WORKFLOW_CHANGES"
        fi
    else
        log "no workflow file changes in this sync"
    fi
fi
```

Update trailing exit:

```bash
emit_status "phases_4_complete"
exit "$EX_OK"
```

Test the script in dry-run; output should now include `[phase 4/8] workflow audit`.

- [ ] **Step 5: Implement Phase 5 (merge into lifeatlas-master)**

Append before the trailing exit:

```bash

# ─── Phase 5: Merge master into lifeatlas-master ────────────────────────
phase 5 8 "merge master into $RELEASE_BRANCH"

if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
    log "merge already in progress on $(git symbolic-ref --short HEAD) — assuming user resolved conflicts and committed; verifying..."
    if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
        # Still mid-merge — user hasn't finished.
        fail "$EX_MERGE_CONFLICT" "merge still in progress; resolve conflicts and `git commit` before re-running"
    fi
    log "merge appears complete; continuing"
else
    if [ "$DRY_RUN" -eq 1 ]; then
        log "(dry-run) would: git checkout $RELEASE_BRANCH && git merge $MASTER_BRANCH"
    else
        git checkout "$RELEASE_BRANCH"
        if ! git merge --no-edit "$MASTER_BRANCH"; then
            log "merge produced conflicts. Files needing resolution:"
            git status --porcelain | grep '^UU\|^AA\|^DD' | sed 's/^/  /' >&2
            log "Resolve manually, then 'git commit' the merge and re-run this script."
            emit_status "merge_conflict"
            exit "$EX_MERGE_CONFLICT"
        fi
    fi
fi
```

Update trailing exit:

```bash
emit_status "phases_5_complete"
exit "$EX_OK"
```

- [ ] **Step 6: Implement Phase 6 (Cargo.toml base-version reconciliation) and Phase 7 (cargo check) and Phase 8 (report)**

Append before the trailing exit:

```bash

# ─── Phase 6: Reconcile Cargo.toml base version ─────────────────────────
phase 6 8 "reconcile Cargo.toml base version"

# Parse the upstream base from master's Cargo.toml (e.g., "0.7.4").
UPSTREAM_BASE=$(git show "$MASTER_BRANCH:Cargo.toml" | sed -n 's/^version = "\([0-9]*\.[0-9]*\.[0-9]*\)"$/\1/p' | head -1)
if [ -z "$UPSTREAM_BASE" ]; then
    fail "$EX_PRECONDITION" "could not parse upstream base version from $MASTER_BRANCH:Cargo.toml"
fi

# Parse the current lifeatlas-master version (e.g., "0.7.3-la.1.5").
CURRENT_LA_VERSION=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' Cargo.toml | head -1)
if [ -z "$CURRENT_LA_VERSION" ]; then
    fail "$EX_PRECONDITION" "could not parse current Cargo.toml version on $RELEASE_BRANCH"
fi

# Decompose the LA version: <base>-la.<MAJOR>.<MINOR>
CURRENT_BASE=$(echo "$CURRENT_LA_VERSION" | sed -n 's/^\([0-9]*\.[0-9]*\.[0-9]*\)-la\.[0-9]*\.[0-9]*$/\1/p')
LA_SUFFIX=$(echo "$CURRENT_LA_VERSION" | sed -n 's/^[0-9]*\.[0-9]*\.[0-9]*\(-la\.[0-9]*\.[0-9]*\)$/\1/p')

if [ -z "$CURRENT_BASE" ] || [ -z "$LA_SUFFIX" ]; then
    fail "$EX_PRECONDITION" "Cargo.toml version '$CURRENT_LA_VERSION' is not in <base>-la.<MAJOR>.<MINOR> form"
fi

if [ "$CURRENT_BASE" = "$UPSTREAM_BASE" ]; then
    log "Cargo.toml base version unchanged ($UPSTREAM_BASE)"
else
    NEW_LA_VERSION="${UPSTREAM_BASE}${LA_SUFFIX}"
    log "upstream base bumped: $CURRENT_BASE -> $UPSTREAM_BASE; setting Cargo.toml to $NEW_LA_VERSION"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "(dry-run) would: rewrite Cargo.toml versions to $NEW_LA_VERSION and commit"
    else
        # Replace every occurrence of the previous version with the new one.
        # Same sed mechanics as Task 3 step 2.
        sed -i "s/version = \"${CURRENT_LA_VERSION}\"/version = \"${NEW_LA_VERSION}\"/g" Cargo.toml
        cargo check --workspace 2>&1 | tail -5 >&2 || \
            fail "$EX_CARGO_CHECK" "cargo check failed after Cargo.toml version reconciliation"
        git add Cargo.toml Cargo.lock
        git commit -m "chore(release): reconcile Cargo.toml base to ${UPSTREAM_BASE} after upstream sync"
    fi
fi

# ─── Phase 7: Sanity check (cargo check) ────────────────────────────────
phase 7 8 "cargo check"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: cargo check --all-targets --locked"
else
    if ! cargo check --all-targets --locked 2>&1 | tail -10 >&2; then
        emit_status "cargo_check_failed"
        exit "$EX_CARGO_CHECK"
    fi
fi

# ─── Phase 8: Report ────────────────────────────────────────────────────
phase 8 8 "report"

log "----- patches still on $RELEASE_BRANCH (vs $MASTER_BRANCH) -----"
git log "$MASTER_BRANCH..$RELEASE_BRANCH" --oneline >&2 || true

if [ "${OLD_MASTER_TIP:-}" != "${NEW_MASTER_TIP:-}" ] && [ -n "${OLD_MASTER_TIP:-}" ]; then
    log "----- upstream changes pulled in this sync -----"
    git log "${OLD_MASTER_TIP}..${NEW_MASTER_TIP}" --oneline >&2 || true
fi

log ""
log "Ready to release. Run scripts/release-fork.sh (or --bump-major for an LA epoch bump)."

emit_status "ready_to_release"
exit "$EX_OK"
```

Replace the previous trailing `emit_status "phases_5_complete"; exit "$EX_OK"` lines with nothing — Phase 8 now ends the script.

- [ ] **Step 7: End-to-end dry-run smoke test**

Run: `scripts/sync-from-upstream.sh --dry-run`
Expected: all 8 phases print `[phase N/8] <name>` headers; final stderr line is "Ready to release. ..."; stdout shows `STATUS: ready_to_release`; exit 0.

```bash
scripts/sync-from-upstream.sh --status
```
Expected: `STATUS: clean` and exit 0 (assuming no mid-merge in repo).

- [ ] **Step 8: Real-run smoke test (no risk if clean)**

Run: `scripts/sync-from-upstream.sh`
Expected outcomes (any of these, depending on repo state):
- "master is already in sync with upstream and origin" → workflow audit skipped → merge runs and is no-op → `STATUS: ready_to_release`. Safe.
- Workflow files actually differ between old and new master tip → exits with `STATUS: workflow_changes_detected` and code 20. Audit and re-run with `--ack-workflow-changes`.
- Merge conflict → exits with `STATUS: merge_conflict` and code 10; resolve manually, commit, re-run.

If the script reaches `STATUS: ready_to_release`, no commits are produced unless the upstream base actually advanced. Verify with `git log -3 --oneline`.

- [ ] **Step 9: Commit**

```bash
git add scripts/sync-from-upstream.sh
git commit -m "feat(scripts): add sync-from-upstream.sh for fork weekly sync"
```

---

## Task 7: `scripts/release-fork.sh`

**Files:**
- Create: `scripts/release-fork.sh`

**Why:** This is the maintainer's release entry point. Assumes `sync-from-upstream.sh` exited 0; produces one fork release: builds binary in pinned docker, packages with web/dist, tags, publishes to GitHub Releases, builds and pushes docker image to GHCR, smoke-verifies. Each phase is idempotent on rerun so partial failures recover cleanly.

- [ ] **Step 1: Create the script skeleton with flag parsing and exit codes**

Create file `scripts/release-fork.sh`:

```bash
#!/usr/bin/env bash
# release-fork.sh — produce one fork release.
#
# Assumes sync-from-upstream.sh has been run and exited 0. Builds the
# binary in a pinned docker image, packages, tags, publishes to GitHub
# Releases, and pushes the docker image to GHCR.
#
# Exit codes (matches sync-from-upstream.sh contract):
#   0   released (or up-to-date for --status)
#   30  cargo test failed
#   40  precondition failure
#   1   uncategorized error

set -euo pipefail

EX_OK=0
EX_CARGO_TEST=30
EX_PRECONDITION=40

# Configuration.
ORIGIN_REMOTE="origin"
MASTER_BRANCH="master"
RELEASE_BRANCH="lifeatlas-master"
FORK_REPO="THDQD/zeroclaw-la-fork"
GHCR_REPO="ghcr.io/thdqd/zeroclaw-la-fork"  # GHCR requires lowercase
BUILDER_IMAGE="zeroclaw-builder:rust1.93"
TARGET_TRIPLE="x86_64-unknown-linux-gnu"

# Cargo features for fork builds. Adjust as the fork's needs evolve.
LIFEATLAS_RELEASE_FEATURES="agent-runtime,channel-matrix"

# Flags.
DRY_RUN=0
STATUS_ONLY=0
BUMP_MAJOR=0
INTERACTIVE=0
FEATURES_OVERRIDE=""

usage() {
    cat <<'USAGE'
release-fork.sh — produce one LifeAtlas fork release.

Usage: scripts/release-fork.sh [flags]

Flags:
  --dry-run            Print what each phase would do; make no changes.
  --status             Report release-readiness state and exit.
  --bump-major         Increment the LA MAJOR version, reset MINOR to 1.
  --features <list>    Override LIFEATLAS_RELEASE_FEATURES for this build.
  --interactive        Re-enable optional confirmation prompts.
  --help               Print this help.

Exit codes:
  0   released
  30  cargo_test_failed
  40  precondition_failure
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --status) STATUS_ONLY=1 ;;
        --bump-major) BUMP_MAJOR=1 ;;
        --features) shift; FEATURES_OVERRIDE="$1" ;;
        --interactive) INTERACTIVE=1 ;;
        --help|-h) usage; exit "$EX_OK" ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit "$EX_PRECONDITION" ;;
    esac
    shift
done

log() { echo "[release-fork] $*" >&2; }
phase() { echo "" >&2; echo "[phase $1/$2] $3" >&2; }
fail() {
    local code="$1"; shift
    echo "ERROR: $*" >&2
    emit_status "${1:-failed}"
    exit "$code"
}
emit_status() { echo "STATUS: $1"; }

# Skeleton placeholder (replaced in next step).
log "(skeleton — phases not yet wired)"
emit_status "skeleton"
exit "$EX_OK"
```

Make executable:

```bash
chmod +x scripts/release-fork.sh
```

Test: `scripts/release-fork.sh --help` prints usage; `scripts/release-fork.sh` shows skeleton message + `STATUS: skeleton` + exit 0.

- [ ] **Step 2: Implement Phase 1 (preflight) and Phase 2 (compute new version)**

Replace the skeleton placeholder with:

```bash
# ─── Phase 1: Preflight ─────────────────────────────────────────────────
phase 1 13 "preflight"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "not a git repository"
fi

CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
if [ "$CURRENT_BRANCH" != "$RELEASE_BRANCH" ]; then
    fail "$EX_PRECONDITION" "must be on $RELEASE_BRANCH (currently on $CURRENT_BRANCH)"
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "$EX_PRECONDITION" "working tree has uncommitted changes"
fi

if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    fail "$EX_PRECONDITION" "merge in progress; finish or abort it first"
fi

# Required tools.
for tool in cargo docker gh jq tar sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "$EX_PRECONDITION" "required tool '$tool' not on PATH"
    fi
done

if ! gh auth status >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "gh is not authenticated; run 'gh auth login'"
fi

# Verify repo-level Actions are disabled (the failsafe that prevents
# upstream workflows from firing on the fork).
ACTIONS_ENABLED=$(gh api "/repos/$FORK_REPO/actions/permissions" --jq '.enabled' 2>/dev/null || echo "unknown")
if [ "$ACTIONS_ENABLED" != "false" ]; then
    fail "$EX_PRECONDITION" \
        "GitHub Actions on $FORK_REPO must be disabled at repo level (got: '$ACTIONS_ENABLED'). \
Settings -> Actions -> 'Disable actions'."
fi

# Builder image must already exist locally.
if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" \
        "builder image '$BUILDER_IMAGE' not found. Run: docker build -f Dockerfile.builder -t $BUILDER_IMAGE ."
fi

# lifeatlas-master must be at-or-ahead of master.
git fetch "$ORIGIN_REMOTE" --quiet
if ! git merge-base --is-ancestor "$MASTER_BRANCH" "$RELEASE_BRANCH"; then
    fail "$EX_PRECONDITION" "$RELEASE_BRANCH is not at or ahead of $MASTER_BRANCH; run sync-from-upstream.sh first"
fi

# ─── Phase 2: Compute new version ───────────────────────────────────────
phase 2 13 "compute new version"

CURRENT_VERSION=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' Cargo.toml | head -1)
log "current Cargo.toml version: $CURRENT_VERSION"

# Decompose <base>-la.<MAJOR>.<MINOR>.
BASE=$(echo "$CURRENT_VERSION" | sed -n 's/^\([0-9]*\.[0-9]*\.[0-9]*\)-la\.[0-9]*\.[0-9]*$/\1/p')
MAJOR=$(echo "$CURRENT_VERSION" | sed -n 's/^[0-9]*\.[0-9]*\.[0-9]*-la\.\([0-9]*\)\.[0-9]*$/\1/p')
MINOR=$(echo "$CURRENT_VERSION" | sed -n 's/^[0-9]*\.[0-9]*\.[0-9]*-la\.[0-9]*\.\([0-9]*\)$/\1/p')

if [ -z "$BASE" ] || [ -z "$MAJOR" ] || [ -z "$MINOR" ]; then
    fail "$EX_PRECONDITION" "Cargo.toml version '$CURRENT_VERSION' is not in <base>-la.<MAJOR>.<MINOR> form"
fi

if [ "$BUMP_MAJOR" -eq 1 ]; then
    NEW_MAJOR=$((MAJOR + 1))
    NEW_MINOR=1
    log "--bump-major: MAJOR $MAJOR -> $NEW_MAJOR; MINOR reset to 1"
else
    NEW_MAJOR="$MAJOR"
    NEW_MINOR=$((MINOR + 1))
    log "MINOR $MINOR -> $NEW_MINOR"
fi

NEW_VERSION="${BASE}-la.${NEW_MAJOR}.${NEW_MINOR}"
NEW_TAG="v${NEW_VERSION}"
log "new version: $NEW_VERSION (tag: $NEW_TAG)"

# Refuse if the tag already exists (locally or on origin).
if git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "tag $NEW_TAG already exists locally"
fi
if git ls-remote --exit-code --tags "$ORIGIN_REMOTE" "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "tag $NEW_TAG already exists on $ORIGIN_REMOTE"
fi

if [ "$STATUS_ONLY" -eq 1 ]; then
    emit_status "ready_to_release_as_$NEW_VERSION"
    exit "$EX_OK"
fi

# Subsequent phases will be appended in later steps.
emit_status "phases_2_complete"
exit "$EX_OK"
```

Test:

```bash
scripts/release-fork.sh --status 2>&1 | tail -10
```

Expected: stderr shows `[phase 1/13] preflight`, `[phase 2/13] compute new version`. Stdout shows `STATUS: ready_to_release_as_0.7.3-la.1.1` (the next planned tag).

```bash
scripts/release-fork.sh --status --bump-major 2>&1 | tail -3
```

Expected: stdout shows `STATUS: ready_to_release_as_0.7.3-la.2.1`.

- [ ] **Step 3: Implement Phase 3 (bump version in repo) and Phase 4 (cargo test)**

Append before the trailing `emit_status "phases_2_complete"; exit "$EX_OK"`:

```bash

# ─── Phase 3: Bump version in repo ──────────────────────────────────────
phase 3 13 "bump version in repo"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: sed Cargo.toml; cargo check --workspace --locked; git commit"
else
    sed -i "s/version = \"${CURRENT_VERSION}\"/version = \"${NEW_VERSION}\"/g" Cargo.toml
    cargo check --workspace 2>&1 | tail -5 >&2 || \
        fail "$EX_CARGO_TEST" "cargo check failed after version bump"
    git add Cargo.toml Cargo.lock
    git commit -m "chore(release): $NEW_TAG"
fi

# ─── Phase 4: Run tests in pinned builder image ─────────────────────────
phase 4 13 "cargo test in $BUILDER_IMAGE"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run ... cargo test --workspace --release --locked"
else
    # Skip the `live` test binary (requires LLM provider credentials per
    # Cargo.toml line ~384). Run lib + bins + the three integration test
    # binaries explicitly.
    if ! docker run --rm \
            -u "$(id -u):$(id -g)" \
            -v "$PWD:/work" \
            -w /work \
            "$BUILDER_IMAGE" \
            sh -c 'cargo test --workspace --release --locked --lib --bins \
                && cargo test --release --locked --test component \
                && cargo test --release --locked --test integration \
                && cargo test --release --locked --test system' 2>&1 | tail -30 >&2; then
        log "tests failed; rolling back version bump"
        git reset --hard HEAD^
        emit_status "cargo_test_failed"
        exit "$EX_CARGO_TEST"
    fi
fi
```

Update the trailing exit:

```bash
emit_status "phases_4_complete"
exit "$EX_OK"
```

Test in dry-run: `scripts/release-fork.sh --dry-run 2>&1 | tail -15`. Expected: phases 3 and 4 print their headers and `(dry-run) would: ...` lines.

- [ ] **Step 4: Implement Phase 5 (build binary with option_env! verification)**

Append before the trailing exit:

```bash

# ─── Phase 5: Build release binary ──────────────────────────────────────
phase 5 13 "build release binary"

EFFECTIVE_FEATURES="${FEATURES_OVERRIDE:-$LIFEATLAS_RELEASE_FEATURES}"
log "features: $EFFECTIVE_FEATURES"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run ... ZEROCLAW_UPDATE_REPO=$FORK_REPO cargo build --release --target $TARGET_TRIPLE"
else
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "$PWD:/work" \
        -w /work \
        -e "ZEROCLAW_UPDATE_REPO=$FORK_REPO" \
        "$BUILDER_IMAGE" \
        cargo build --release --target "$TARGET_TRIPLE" --locked --features "$EFFECTIVE_FEATURES"

    BINARY_PATH="target/$TARGET_TRIPLE/release/zeroclaw"
    if [ ! -f "$BINARY_PATH" ]; then
        fail 1 "expected binary $BINARY_PATH not found after cargo build"
    fi

    # Verify --version reports the new version.
    BINARY_VERSION=$("$BINARY_PATH" --version 2>&1)
    if ! echo "$BINARY_VERSION" | grep -qF "$NEW_VERSION"; then
        fail 1 "binary --version output '$BINARY_VERSION' does not contain $NEW_VERSION"
    fi
    log "binary --version: $BINARY_VERSION"

    # Verify the option_env! propagated by checking the embedded URL.
    if ! strings "$BINARY_PATH" | grep -qF "$FORK_REPO"; then
        fail 1 "ZEROCLAW_UPDATE_REPO did not propagate to the binary; aborting"
    fi
    log "verified ZEROCLAW_UPDATE_REPO=$FORK_REPO is embedded in the binary"
fi
```

Update trailing exit accordingly. Test in dry-run.

- [ ] **Step 5: Implement Phase 6 (build web) and Phase 7 (package tarball)**

Append before the trailing exit:

```bash

# ─── Phase 6: Build web dashboard ───────────────────────────────────────
phase 6 13 "build web dashboard"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run ... npm ci && npm run build (in /work/web)"
else
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "$PWD:/work" \
        -w /work/web \
        "$BUILDER_IMAGE" \
        sh -c 'npm ci && npm run build' 2>&1 | tail -10 >&2

    if [ ! -d web/dist ]; then
        fail 1 "expected web/dist/ not found after npm run build"
    fi
fi

# ─── Phase 7: Package tarball ───────────────────────────────────────────
phase 7 13 "package tarball"

ASSET_NAME="zeroclaw-${TARGET_TRIPLE}.tar.gz"
SHA_FILE="SHA256SUMS"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: produce $ASSET_NAME and $SHA_FILE in repo root"
else
    rm -rf staging "$ASSET_NAME" "$SHA_FILE"
    mkdir -p staging/web
    cp "target/$TARGET_TRIPLE/release/zeroclaw" staging/
    cp -r web/dist staging/web/dist
    ( cd staging && tar czf "../$ASSET_NAME" zeroclaw web/dist )
    sha256sum "$ASSET_NAME" > "$SHA_FILE"
    log "produced $ASSET_NAME ($(du -h "$ASSET_NAME" | awk '{print $1}'))"
    cat "$SHA_FILE" >&2
fi
```

- [ ] **Step 6: Implement Phase 8 (release notes) and Phase 9 (tag and push)**

Append:

```bash

# ─── Phase 8: Generate release notes ────────────────────────────────────
phase 8 13 "generate release notes"

NOTES_FILE="release-notes.md"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: write $NOTES_FILE from CHANGELOG-next.md or git log"
else
    if [ -f CHANGELOG-next.md ]; then
        log "using CHANGELOG-next.md as release notes"
        cp CHANGELOG-next.md "$NOTES_FILE"
    else
        # Find the previous fork tag to bound the log range.
        PREV_TAG=$(git tag -l 'v*-la.*' --sort=-v:refname | head -1 || true)
        if [ -n "$PREV_TAG" ]; then
            RANGE="${PREV_TAG}..HEAD"
        else
            RANGE="HEAD"
        fi
        {
            echo "## Changes since ${PREV_TAG:-fork inception}"
            echo
            git log "$RANGE" --pretty='format:- %s' --no-merges \
                | grep -iE '^- feat(\(|:)' \
                | sed 's/ (#[0-9]*)$//' \
                | sort -uf
            echo
            echo
            echo "_Built from \`${BASE}\` upstream base; LA \`${NEW_MAJOR}.${NEW_MINOR}\`._"
        } > "$NOTES_FILE"
        log "wrote $NOTES_FILE"
    fi
fi

# ─── Phase 9: Tag and push ──────────────────────────────────────────────
phase 9 13 "tag and push"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: git tag -a $NEW_TAG; git push $ORIGIN_REMOTE $RELEASE_BRANCH; git push $ORIGIN_REMOTE $NEW_TAG"
else
    # Idempotency: skip if tag already exists at HEAD (re-running after partial failure).
    if git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
        EXISTING_TAG_COMMIT=$(git rev-parse "$NEW_TAG^{commit}")
        HEAD_COMMIT=$(git rev-parse HEAD)
        if [ "$EXISTING_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
            fail 1 "tag $NEW_TAG exists but does not point at HEAD; manual cleanup required"
        fi
        log "tag $NEW_TAG already exists at HEAD; skipping tag step"
    else
        git tag -a "$NEW_TAG" -m "Release $NEW_TAG"
    fi
    git push "$ORIGIN_REMOTE" "$RELEASE_BRANCH"
    git push "$ORIGIN_REMOTE" "$NEW_TAG"
fi
```

- [ ] **Step 7: Implement Phase 10 (gh release create) and Phase 11 (docker build/push)**

Append:

```bash

# ─── Phase 10: gh release create ────────────────────────────────────────
phase 10 13 "gh release create"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: gh release create $NEW_TAG $ASSET_NAME $SHA_FILE --repo $FORK_REPO --latest"
else
    # Idempotency: if the release already exists at this tag, skip creation.
    if gh release view "$NEW_TAG" --repo "$FORK_REPO" >/dev/null 2>&1; then
        log "release $NEW_TAG already exists; skipping create"
    else
        gh release create "$NEW_TAG" "$ASSET_NAME" "$SHA_FILE" \
            --repo "$FORK_REPO" \
            --title "$NEW_TAG" \
            --notes-file "$NOTES_FILE" \
            --latest
    fi
fi

# ─── Phase 11: Build and push docker image to GHCR ──────────────────────
phase 11 13 "docker build and push to GHCR"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker build -f Dockerfile.ci ...; docker push $GHCR_REPO:$NEW_TAG and :latest"
else
    # GHCR auth (uses gh's token; safe to re-run).
    GH_TOKEN_VALUE=$(gh auth token)
    echo "$GH_TOKEN_VALUE" | docker login ghcr.io -u thdqd --password-stdin >/dev/null

    # Prepare a docker-context dir that mirrors what upstream's CI assembles
    # for Dockerfile.ci: pre-built binaries under bin/amd64/zeroclaw plus web/dist
    # plus a default config.
    # Dockerfile.ci expects this exact layout (see Dockerfile.ci:8-20):
    #   bin/${TARGETARCH}/zeroclaw           — the binary
    #   bin/${TARGETARCH}/web/dist           — web dashboard
    #   zeroclaw-data/.zeroclaw/config.toml  — default runtime config
    # For x86_64-unknown-linux-gnu the corresponding TARGETARCH is "amd64".
    DOCKER_CTX=$(mktemp -d)
    trap 'rm -rf "$DOCKER_CTX"' EXIT

    mkdir -p "$DOCKER_CTX/bin/amd64/web"
    cp "target/$TARGET_TRIPLE/release/zeroclaw" "$DOCKER_CTX/bin/amd64/zeroclaw"
    cp -r web/dist "$DOCKER_CTX/bin/amd64/web/dist"

    mkdir -p "$DOCKER_CTX/zeroclaw-data/.zeroclaw" "$DOCKER_CTX/zeroclaw-data/workspace"
    printf '%s\n' \
        'workspace_dir = "/zeroclaw-data/workspace"' \
        'config_path = "/zeroclaw-data/.zeroclaw/config.toml"' \
        'api_key = ""' \
        'default_provider = "openrouter"' \
        'default_model = "anthropic/claude-sonnet-4-20250514"' \
        'default_temperature = 0.7' \
        '' \
        '[gateway]' \
        'port = 42617' \
        'host = "[::]"' \
        'allow_public_bind = true' \
        'web_dist_dir = "/zeroclaw-data/web/dist"' \
        > "$DOCKER_CTX/zeroclaw-data/.zeroclaw/config.toml"

    cp Dockerfile.ci "$DOCKER_CTX/Dockerfile"

    docker build \
        --platform linux/amd64 \
        --build-arg TARGETARCH=amd64 \
        -f "$DOCKER_CTX/Dockerfile" \
        -t "$GHCR_REPO:$NEW_TAG" \
        -t "$GHCR_REPO:latest" \
        "$DOCKER_CTX"

    docker push "$GHCR_REPO:$NEW_TAG"
    docker push "$GHCR_REPO:latest"

    log "pushed $GHCR_REPO:$NEW_TAG and :latest"
fi
```

The layout above matches `Dockerfile.ci` lines 8-20 exactly: `bin/amd64/zeroclaw`, `bin/amd64/web/dist`, and `zeroclaw-data/`. The `TARGETARCH=amd64` build-arg drives the `${TARGETARCH}` substitutions in the Dockerfile's COPY directives. If `Dockerfile.ci` later changes its expected COPY sources, update Phase 11 to match.

- [ ] **Step 8: Implement Phase 12 (smoke verify) and Phase 13 (report)**

Append:

```bash

# ─── Phase 12: Smoke verification ───────────────────────────────────────
phase 12 13 "smoke verification"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run --rm $GHCR_REPO:$NEW_TAG --version; gh api releases/latest"
else
    # Pull the just-pushed image (force pull, no cache) and verify --version.
    docker pull "$GHCR_REPO:$NEW_TAG" >/dev/null
    IMAGE_VERSION=$(docker run --rm "$GHCR_REPO:$NEW_TAG" --version 2>&1)
    if ! echo "$IMAGE_VERSION" | grep -qF "$NEW_VERSION"; then
        fail 1 "GHCR image --version '$IMAGE_VERSION' does not contain $NEW_VERSION"
    fi
    log "GHCR image reports: $IMAGE_VERSION"

    # Verify GH releases API reports the new release as latest.
    LATEST_TAG=$(gh api "/repos/$FORK_REPO/releases/latest" --jq '.tag_name')
    if [ "$LATEST_TAG" != "$NEW_TAG" ]; then
        fail 1 "GH releases latest is '$LATEST_TAG', expected '$NEW_TAG'"
    fi
    log "GH releases /latest = $LATEST_TAG"
fi

# ─── Phase 13: Report ───────────────────────────────────────────────────
phase 13 13 "report"

log ""
log "======================================================================"
log "  Released $NEW_TAG"
log "  GH release: https://github.com/$FORK_REPO/releases/tag/$NEW_TAG"
log "  GHCR image: $GHCR_REPO:$NEW_TAG"
log "  Asset:      $ASSET_NAME"
if [ -f "$SHA_FILE" ]; then
    log "  Checksum:   $(awk '{print $1}' "$SHA_FILE")"
fi
log "======================================================================"

emit_status "released"
exit "$EX_OK"
```

Replace the previous trailing `emit_status "phases_4_complete"; exit "$EX_OK"` so Phase 13 is the actual exit.

- [ ] **Step 9: End-to-end dry-run smoke test**

Run: `scripts/release-fork.sh --dry-run 2>&1 | tail -30`
Expected: all 13 phases print their headers; `(dry-run) would: ...` log lines for the side-effect phases (3-12); final stdout shows `STATUS: released`; exit 0.

```bash
scripts/release-fork.sh --status
```
Expected: `STATUS: ready_to_release_as_0.7.3-la.1.1` and exit 0.

```bash
scripts/release-fork.sh --status --bump-major
```
Expected: `STATUS: ready_to_release_as_0.7.3-la.2.1`.

- [ ] **Step 10: Commit**

```bash
git add scripts/release-fork.sh
git commit -m "feat(scripts): add release-fork.sh for fork release publication"
```

---

## Task 8: Optional `docs/BOOTSTRAP.md`

**Files:**
- Create: `docs/BOOTSTRAP.md`

**Why:** Documents the contract between this fork's docker image and `claw-auth-proxy` (the bootstrap consumer). Not required for the release pipeline to function, but spares the proxy's maintainer from spelunking source to figure out env vars and volume conventions.

- [ ] **Step 1: Create the file**

Create `docs/BOOTSTRAP.md`:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/BOOTSTRAP.md
git commit -m "docs: add BOOTSTRAP.md describing fork image contract"
```

---

## Task 9: Final verification — exercise the pipeline in dry-run

**Files:** none (verification only)

**Why:** Ensure the two scripts compose correctly end-to-end. Catches issues like phase-numbering drift, exit-code mismatches, or one script's output being unparseable by the other's caller before they bite during a real release.

- [ ] **Step 1: Dry-run sync, verify status**

```bash
scripts/sync-from-upstream.sh --dry-run 2>&1 | tail -10
scripts/sync-from-upstream.sh --dry-run | head -1
```

Expected: stderr ends with "Ready to release. Run scripts/release-fork.sh ..."; stdout (one-line `STATUS:`) is `STATUS: ready_to_release`.

- [ ] **Step 2: Dry-run release, verify status**

```bash
scripts/release-fork.sh --dry-run 2>&1 | tail -15
scripts/release-fork.sh --dry-run | head -1
```

Expected: stderr ends with the "Released vX.Y.Z" banner block; stdout shows `STATUS: released`.

- [ ] **Step 3: Verify `--status` modes**

```bash
scripts/sync-from-upstream.sh --status
scripts/release-fork.sh --status
```

Expected: each prints exactly one `STATUS: ...` line and exits 0. No commits, no fetches, no side effects.

- [ ] **Step 4: Verify `--help` for both scripts**

```bash
scripts/sync-from-upstream.sh --help
scripts/release-fork.sh --help
```

Expected: both print usage including their full flag list and exit-code reference; exit 0.

- [ ] **Step 5: Verify exit codes are non-zero on precondition failure**

Try a precondition failure to confirm the contract:

```bash
# Run from a non-repo directory.
( cd /tmp && /home/thd/wd/wn/Claw/zeroclaw/scripts/sync-from-upstream.sh; echo "exit=$?" )
```

Expected: stderr says "ERROR: not a git repository"; stdout has `STATUS: ...`; `exit=40`.

- [ ] **Step 6: Confirm builder image is still functional**

```bash
docker run --rm zeroclaw-builder:rust1.93 sh -c 'cargo --version && rustc --version && node --version' 2>&1 | tail -3
```

Expected: cargo 1.93.0, rustc 1.93.0, node v22.x.x.

- [ ] **Step 7: Verify the option_env! redirect would actually work for a real build**

Simulate the build step with the env var, and inspect the binary:

```bash
docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$PWD:/work" \
    -w /work \
    -e "ZEROCLAW_UPDATE_REPO=THDQD/zeroclaw-la-fork" \
    zeroclaw-builder:rust1.93 \
    cargo build --release --target x86_64-unknown-linux-gnu --bin zeroclaw

strings target/x86_64-unknown-linux-gnu/release/zeroclaw | grep -F 'THDQD/zeroclaw-la-fork' | head -3
```

Expected: at least one line of output containing `THDQD/zeroclaw-la-fork`. If empty, the `option_env!` patch did not propagate to the binary — investigate before proceeding to a real release. (Common cause: forgetting `-e ZEROCLAW_UPDATE_REPO=...` in the docker invocation.)

- [ ] **Step 8: Done — pipeline ready for first real release**

Summarize the pipeline state:

```bash
git log --oneline -10
ls scripts/
ls Dockerfile.builder
grep '^version' Cargo.toml | head -1
```

Expected:
- Recent commits include the option_env! patch, semver comparator, version bump, Dockerfile.builder, deleted workflows, both scripts, and (optionally) BOOTSTRAP.md.
- `scripts/sync-from-upstream.sh` and `scripts/release-fork.sh` both exist and are executable.
- `Dockerfile.builder` exists.
- `version = "0.7.3-la.1.0"` (the next release will be `0.7.3-la.1.1`).

The first real release is gated on a manual decision: when ready, run `scripts/sync-from-upstream.sh && scripts/release-fork.sh` (without `--dry-run`). The plan's job ends at "infrastructure ready"; the first publication is operational.

---

## First-time setup checklist (one-time, before first real release)

These are operational steps the maintainer performs once. Not part of the implementation but listed here so they're not forgotten.

- [ ] **Disable Actions on the fork** — GitHub web UI → Settings → Actions → General → "Disable actions" → Save.
- [ ] **Verify the disable took effect** — `gh api /repos/THDQD/zeroclaw-la-fork/actions/permissions --jq '.enabled'` returns `false`.
- [ ] **Optional: switch fork's default branch** — to `lifeatlas-master` once that branch is created (Settings → General → Default branch).
- [ ] **Authenticate `gh` with `write:packages` scope** — `gh auth refresh -s write:packages` (needed for GHCR pushes).
- [ ] **Authenticate docker against GHCR** — `gh auth token | docker login ghcr.io -u thdqd --password-stdin`. The release script re-runs this if needed.
- [ ] **Pre-build the builder image** — `docker build -f Dockerfile.builder -t zeroclaw-builder:rust1.93 .`. Subsequent runs reuse the cache.
- [ ] **Confirm `Dockerfile.ci` is unchanged from when this plan was written** — the script's Phase 11 layout matches `Dockerfile.ci` lines 8-20 (binary at `bin/${TARGETARCH}/zeroclaw`, web at `bin/${TARGETARCH}/web/dist`). If `Dockerfile.ci` was modified after this plan was written, re-read it and update Phase 11 of the script accordingly.

After that, `scripts/sync-from-upstream.sh && scripts/release-fork.sh` produces real release `v0.7.3-la.1.1` end to end.
