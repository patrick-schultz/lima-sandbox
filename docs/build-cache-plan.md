# Plan: per-workspace target dirs and kache in the sandbox

Both stages are implemented. This file is kept as the record of why, what was measured, and the
deferred host idea.

## Why

All guest builds share `~/.cargo-target`. Cargo's output filenames hash the package and its
workspace-relative path, not the absolute path, so two jj workspaces of one project write the same
binary paths. On 2026-10-01 the agents in `datafusion-sandbox/workspaces/ws1` and `ws2` overwrote
each other's lib test binary. ws1 spent about 17 minutes calling a real failure flaky, and some of
its passing runs and clippy results came from ws2's code. It spotted the problem from the test
count, 293 against 297. Transcript:
`~/.agent-transcripts/sandbox/claude-projects/-Users-pschulz-dev-datafusion-sandbox-workspaces-ws1/fa474bc6-50d2-4999-b77d-f02ec0c7a1c0.jsonl`.

The shared dir also serializes concurrent builds on cargo's target-dir lock.

Per-workspace target dirs fix correctness. kache
([kunobi-ninja/kache](https://github.com/kunobi-ninja/kache)) then makes them cheap: its cache key
normalizes away the checkout path, so a new workspace gets dependency and workspace-crate hits from
the others. Cargo has no cross-workspace artifact cache yet, not even on nightly.

## Scope

- Guest only. No cache sharing with the host. The two never hit each other, because every key
  contains `rustc -vV` output and the target triple. Sharing would also let the sandbox write
  artifacts that the host links.
- Rust only. No `kache cc` or C/C++ shims; build-script caching already restores cc-rs `OUT_DIR`s.
- Two stages, each its own change. Stage 2 must beat stage 1, and any stale-artifact bug after
  stage 2 is attributable to kache.

## Stage 1: per-workspace target dirs on a data disk

### Data disk

- Add a Lima additional disk named `cargo`: 150 GiB, sparse, `fsType: xfs`. On noble, `mkfs.xfs`
  enables reflink by default. Lima mounts it at `/mnt/lima-cargo`; the mount point is fixed.
- `bin/apply` creates it with `limactl disk create cargo --size 150GiB` when it is missing.
- It survives `limactl delete`, so a VM rebuild keeps warm build output. This is safe because kache
  keys include the rustc version.
- XFS rather than btrfs: Lima auto-grows XFS after `limactl disk resize`, but not btrfs.
- Layout: `/mnt/lima-cargo/target/<name>` per workspace, plus `/mnt/lima-cargo/kache` from stage 2.
  The kache store and the target dirs must share a filesystem for clones and hardlinks to work.

### cargo wrapper

`~/.local/bin/cargo`, with fish's PATH changed so `~/.local/bin` comes before `~/.cargo/bin`. The
wrapper execs the rustup `cargo` in `~/.cargo/bin`.

- If `CARGO_TARGET_DIR` is already set, change nothing. That covers nested cargo calls and
  explicit overrides.
- Otherwise, find the workspace root with the real
  `cargo locate-project --workspace --message-format plain`. With no cargo workspace, change
  nothing.
- Set `CARGO_TARGET_DIR` to `/mnt/lima-cargo/target/<basename>-<8 hex of the root path hash>`, and
  append `-$SANDBOX_TARGET_SUFFIX` when that is set.
- Implemented without `CARGO_BUILD_BUILD_DIR`. The build-dir then defaults to the target-dir, so it
  is still per workspace, as kache issue #760 requires. It also follows an explicit
  `--target-dir`, such as rust-analyzer's `cargo.targetDir` subdir. Setting it was only needed to
  stop `kache cargo` putting the build-dir on the mount, and stage 2 uses kache as
  `rustc-wrapper` only. Never use the `kache cargo` shim.
- Write `<dir>/.workspace` with the absolute workspace root.
- Remove `build.target-dir` from the generated `~/.cargo/config.toml`.

### Cleanup

Add `guest/sandbox-gc-targets`, installed in `/usr/local/bin`. It deletes target dirs whose
`.workspace` path no longer exists, and runs at boot from `user.sh` and by hand. Agent worktrees
under `~/.claude/worktrees` are the main source of orphans.

### Migration

- Delete the old `~/.cargo-target` (51 GB on the root disk) and the `mkdir` for it in `user.sh`.
- Rewrite the target-dir lines in `README.md`, including the x86_64/GCE section: use
  `SANDBOX_TARGET_SUFFIX=<family>` with `RUSTFLAGS` instead of a hand-made `CARGO_TARGET_DIR`.
- Rewrite `~/.agents/AGENTS-sandbox.md` line 7 to match. That file is host config outside this
  repo, so edit it there. Agents should get binary paths from cargo output, not hardcoded paths.
- README note for editors: set rust-analyzer `cargo.targetDir = true` so its `check` gets a sub-dir
  and doesn't wait on the build-dir lock behind agent builds.

### Baseline measurement, in datafusion-sandbox

Stage 1 baseline, taken 2026-10-07 in datafusion-sandbox ws1 and ws2:

| Scenario | Result |
| --- | --- |
| Fresh target dir, `cargo nextest run --no-run` (ws2) | 201.7 s, 6.8 GB (ws1 earlier: 174.6 s) |
| ws1 catching up to a new parent revision | 38.5 s |
| One-line edit to `src/lib.rs` in both, `cargo nextest run` concurrently | ws1 41.9 s (build 19.2 s); ws2 61.8 s (build 52.0 s) |

- No target-dir lock waits. Each concurrent build recompiled only its own `datafusion-sandbox`.
- Both printed "Blocking waiting for file lock on package cache", which is cargo's registry lock,
  not the target dir.
- kache can only win the cold-build row. The concurrent rows are compiling the edited crate plus
  running tests.

Repeat on stage 2:

1. Two agents' workspaces run `cargo nextest run` at the same time after a small edit. Record wall
   time and any lock waits.
2. A newly created subagent workspace runs its first `cargo test`. Record wall time.

Also record disk use on `/mnt/lima-cargo` after each run. Adopt stage 2 only if it is clearly
faster than stage 1.

## Stage 2: kache

### Install

- Pin an exact version (currently v1.0.0) in `user.sh`. Use the
  `kache-aarch64-unknown-linux-musl.tar.gz` release asset, verified by sha256, into `~/.local/bin`.
- v1.0.0 has no linux-gnu asset, and `cargo binstall`'s musl fallback is unverified.
- Bump the version deliberately. Releases are very frequent, and cache formats may change within
  1.x, which only costs misses.

### Config, generated by provisioning and overwritten on boot

Never run `kache init`.

- Generated `~/.cargo/config.toml` gets `build.rustc-wrapper` set to the kache binary.
- `~/.config/kache/config.toml`:
  - `cache.local_store = "/mnt/lima-cargo/kache"`
  - `cache.local_max_size = 60 GiB`. The default of 5% of the disk is too small.
  - No remote.
- Daemon: run `kache daemon install` (systemd user unit `kache.service`) only when the unit is
  missing. Remote settings would belong in the config file, not the environment, because the unit
  captures its environment at install time.
  - Keep orphaned-target cleanup on. It only removes dirs whose workspace is gone and that have
    been unused for a day, and never dirs held by a running cargo.
  - Keep the low-free-space recovery on (10 GiB floor). The data disk holds only disposable output.
- Keep `sandbox-gc-targets` if kache's cleanup misses dirs; drop it otherwise.

### Known gaps to accept or salt around

- mold's version is not in the key (only the first line of `cc --version` is). Change
  `KACHE_KEY_SALT` when bumping mold.
- Files read by proc-macros or build scripts without being declared are invisible to the key. Cover
  them with `cache.key_env_vars`, a salt, or `bypass_crates` if one turns up.
- Restored hardlinked outputs are read-only. Run `cargo clean` before building a dir without kache.
- rust-analyzer likely bypasses kache for build scripts via its own `RUSTC_WRAPPER`. This is
  inferred, not documented, and harmless.

### Agent instructions

Add a short line to `AGENTS-sandbox.md`: builds go through kache. If results look inconsistent with
the source, rerun with `KACHE_DISABLED=1 SANDBOX_TARGET_SUFFIX=nokache` and say so in the report.
The suffix matters because restored outputs are read-only.

### Results, 2026-10-08, datafusion-sandbox

Stage 2 is implemented, with one change from the plan: `cache_executables = false`.

| Scenario | No kache | kache default | `cache_executables = false` |
| --- | --- | --- | --- |
| Fresh workspace, cold `nextest --no-run` | 202 s | 36 s | 39 s |
| One workspace, edit + build, rounds 1/2/3 | 21 / 19 / 19 s | 28 / 16 / 25 s | 24 / 12 / 12 s |
| Two workspaces concurrently, edit + build | 19 / 52 s | 45 → 53 → 88 s | 25–68 s, no trend |

- **Default kache:** it compressed and stored every relinked 700–800 MB test and cli binary. Store
  time grew to about 5 minutes per session, and each round got slower.
- **Adaptive incremental off (`KACHE_ADAPTIVE_INCREMENTAL=0`):** worse, at 26–33 s, so it stays on.
- **Concurrent rows:** these are dominated by CPU contention between the two builds.
- **Load-sensitive tests:** `probing_a_plan_that_never_finishes_stops_it_capped` and the cli
  `a_written_probe_records_three_tables…` fail under CPU load, with `rows: 0` for the whole probe
  window. A kache-free binary failed 1 of 10 runs with the CPUs saturated, so this is not a kache
  artifact.
- **`kache doctor`'s "Link layout: EXDEV" error:** a false alarm. It checks the workspace on the
  mount, and real restores were 100% reflinks.

## Later: host

Not decided, only recorded. The host could get its own kache with a separate local store:

- APFS gives copy-on-write restores even for executables.
- A fresh host jj workspace's first build would mostly be hits.
- `cargo clean` and toolchain rebuilds would become cheap.

Revisit after stage 2 has run in the guest for a while.
