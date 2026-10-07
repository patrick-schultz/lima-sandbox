# lima-sandbox

A Lima VM that sandboxes coding agents (Claude Code, Codex) and cross-compiles Rust for x86_64.
The VM is the safety boundary: agents run inside it with permission prompts off, and only the
directories listed in `sandbox.yaml` are visible.

Ubuntu 24.04 arm64 under vz, 8 CPUs, 16 GiB + 8 GiB swap, 100 GiB sparse disk plus a 150 GiB XFS
disk for build output, Rosetta binfmt on, no containerd.

## Layout

| Path | Purpose |
| --- | --- |
| `sandbox.yaml` | Lima template. Mounts, resources, and provision steps that reference the files below. |
| `provision/system.sh` | Root provisioning: apt packages, cross gcc, mold, gh, Node, jj, codex, pyright, swap, fish as login shell. |
| `provision/user.sh` | User provisioning: fish and jj config, rustup (nightly default + stable, x86_64 target), cargo config, cargo wrapper link, kache and its daemon, cargo-binstall, cargo-nextest, uv, claude, agent config symlinks. |
| `guest/sandbox-sync` | Installed at `/usr/local/bin/sandbox-sync` in the guest. Regenerates agent config from `~/.agents`. |
| `guest/sandbox-cargo`, `guest/sandbox-gc-targets` | Installed in `/usr/local/bin`, with `~/.local/bin/cargo` linked to the wrapper. Per-workspace target dirs, see below. |
| `guest/gh`, `guest/gh-token`, `guest/git-credential-sandbox` | Installed in `/usr/local/bin`, with `/usr/bin/gh` linked to the `gh` wrapper. Per-owner GitHub token selection, see below. |
| `bin/apply` | Renders the template and creates or updates the VM. Also creates the `cargo` disk and adds the ssh `Include` on the host. |

Provision scripts run on every boot and are idempotent.

## Host files the VM reads

`~/.agents` is mounted read-only at the guest home. The host `~/.claude` and `~/.codex` point into it
via symlinks, so the sandbox sees the same base config as the host.

| Host file | Guest result |
| --- | --- |
| `~/.agents/claude/settings.json` + `settings-sandbox.json` | `~/.claude/settings.json`, deep-merged with jq. Arrays in the overlay replace, not append. |
| `~/.agents/AGENTS.md` + `AGENTS-sandbox.md` | `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, concatenated. |
| `~/.agents/codex/config-sandbox.toml` | `~/.codex/config.toml`, copied. |
| `~/.agents/skills/` | `~/.claude/skills` symlink, and one symlink per skill in `~/.codex/skills/`. |
| `~/.agents/claude/scripts/` | `~/.claude/scripts` symlink, for the jj worktree hooks. |

After editing any of these on the host, run `sandbox-sync` inside the VM. It also runs at boot.

## Agent transcripts

Session transcripts are written through writable mounts to `~/.agent-transcripts/sandbox/` on the
host, so they outlive the VM and can be analysed alongside host sessions. `bin/apply` creates the
host directories.

| Host dir | Guest dir |
| --- | --- |
| `claude-projects` | `~/.claude/projects` |
| `codex-sessions` | `~/.codex/sessions` |
| `codex-archived-sessions` | `~/.codex/archived_sessions` |

These are dedicated directories, not the host's own `~/.claude/projects` or `~/.codex/sessions`, so
the sandbox never sees host sessions. Codex's SQLite state stays on the VM disk; the `.jsonl` rollouts
are the complete record. Transcripts are written inside the sandbox, so treat them as untrusted input.

## Usage

```
bin/apply                 # create, or stop + apply sandbox.yaml + start
limactl shell sandbox     # fish session in the guest
ssh lima-sandbox          # for Zed, T3 Code, or plain ssh
limactl stop sandbox
```

Mounted projects appear at their host paths, e.g. `/Users/pschulz/dev/datafusion-sandbox`.
Cargo builds go to a per-workspace dir under `/mnt/lima-cargo/target`, never to `target/` on the mount.

### Adding a project

Add a `mounts` entry to `sandbox.yaml`, add a `[projects."..."]` trust entry to
`~/.agents/codex/config-sandbox.toml`, and run `bin/apply`. This repo is deliberately not mounted.

### First run, once per VM

1. `limactl shell sandbox`
2. `claude` and follow the login flow.
3. `codex login` and follow the device flow.
4. For each repo owner you work under, create a fine-grained GitHub token for that owner,
   limited to the repos you mount, with Contents, Issues, and Pull requests read/write.
   Then in the VM: `gh-token add <owner>` and paste it. These are the only credentials in the VM.

### GitHub tokens

Fine-grained tokens are scoped to one resource owner, so the VM keeps one token per owner in
`~/.config/gh-tokens/<owner>` and picks the right one automatically:

- `git` and `jj git push` ask the `git-credential-sandbox` helper, which reads the owner from the
  repo path in the URL.
- `gh` is a wrapper that sets `GH_TOKEN` from the owner in `-R owner/repo` or, failing that, the
  origin remote of the current directory, then runs the real gh. The gh package is diverted to
  `/usr/bin/gh.real` and `/usr/bin/gh` links to the wrapper, so it wins whatever the PATH order.
  Zed, for one, starts agents with `/usr/bin` at the front of PATH.
- `gh-token list` shows which owners have a token. `gh-token rm <owner>` removes one.

No `gh auth login` is needed or wanted. With no matching token, gh runs unauthenticated.

### Target dirs

Each cargo workspace builds into its own `/mnt/lima-cargo/target/<basename>-<hash of path>`, for
example `ws1-54cbfd3e`. The `cargo` wrapper picks the dir from `cargo locate-project --workspace`
and exports `CARGO_TARGET_DIR`; an existing `CARGO_TARGET_DIR` wins. `SANDBOX_TARGET_SUFFIX=<s>`
appends `-<s>`, for builds that should not share a dir, such as different `RUSTFLAGS`.

A shared target dir is unsafe for several workspaces of one project. Cargo's output paths do not
depend on the checkout path, so one workspace's build overwrites the other's binaries, and an
agent ends up testing someone else's code. That happened to datafusion-sandbox's ws1 and ws2.

The wrapper writes the workspace path to `.workspace` in each dir. `sandbox-gc-targets` runs at
boot and deletes dirs whose workspace is gone, such as finished agent worktrees; `-n` lists them
without deleting. It keeps a dir when the workspace's parent is also missing, as with an unmounted
project.

`/mnt/lima-cargo` is the `cargo` Lima disk: sparse, XFS with reflinks, and kept by
`limactl delete`. `limactl disk resize cargo --size <N>GiB` grows it while the VM is stopped.

For rust-analyzer, set `cargo.targetDir = true` in the editor or project config. It then checks
into a `rust-analyzer` subdir and does not wait on the build-dir lock behind agent builds.

### Build cache

[kache](https://github.com/kunobi-ninja/kache) is cargo's `rustc-wrapper`, so per-workspace target
dirs do not mean rebuilding every dependency. Its keys ignore the checkout path, so a fresh
workspace fills from the other workspaces' outputs. On datafusion-sandbox a fresh workspace's
first `nextest --no-run` takes 39 s instead of 202 s. The store is `/mnt/lima-cargo/kache`, on the
same XFS disk as the target dirs, so restores are reflink clones. It is capped at 60 GiB.

- `user.sh` pins the version and sha256. Bump both together, deliberately.
- `cache_executables = false`: storing each relinked 700–800 MB test binary slowed concurrent edit
  loops more every round, and mold relinks them in about a second.
- The `kache.service` user unit runs the daemon. It seeds new target dirs, runs GC, and removes
  target dirs whose workspace was deleted at least a day ago.
- `KACHE_DISABLED=1` bypasses it for one command. Hardlinked outputs are read-only, so use a
  separate target dir (`SANDBOX_TARGET_SUFFIX=nokache`) for builds without kache.
- `kache stats --last-build`, `kache doctor`, `kache targets`. doctor's "Link layout: EXDEV"
  warning is a false alarm here: it compares against the workspace on the mount, not
  `CARGO_TARGET_DIR`.
- mold's version is not part of the key; set `KACHE_KEY_SALT` in the config when bumping mold.

### Linking and memory

Cargo links with mold for both aarch64 and x86_64, through the `cc-mold` and
`x86_64-linux-gnu-cc-mold` wrappers named in `~/.cargo/config.toml`. Selecting the linker there
rather than in rustflags keeps working when `RUSTFLAGS` is set and leaves project rustflags alone.

mold is here for speed. On the datafusion-sandbox test binaries, one link takes about a second with
mold against 20 to 60 seconds with GNU ld, and uses about the same memory, roughly 3 GB. Because the
links finish quickly, they rarely overlap. A `cargo test` rebuild of that crate at default
parallelism took 20 seconds and peaked at 5.5 GB with mold, against 2.5 minutes and 20.6 GB with GNU
ld. Before the VM had swap, that GNU ld peak got ld and rust-analyzer OOM-killed. The 8 GiB swapfile
covers the spikes that remain, so they slow the build down instead of killing processes.

### x86_64 builds

```
cargo build -r --target x86_64-unknown-linux-gnu
```

For a GCE family, take the flags from `python3 python/src/hailtools/gce.py flags <family>` and set
`RUSTFLAGS` plus `SANDBOX_TARGET_SUFFIX=<family>`. Binaries link
against glibc 2.39; if the GCE image is older, add cargo-zigbuild.

Without `RUSTFLAGS`, the project's `-Ctarget-cpu=native` resolves to the arm64 host CPU and rustc
ignores every feature for the x86 target, so you get a baseline x86-64 binary. That is fine for a
smoke test, not for a benchmark build.

The resulting binaries run directly in the VM under Rosetta, as a functional check only. Rosetta
has no AVX-512, and timings under it mean nothing.

## Rebuilding from scratch

`limactl delete sandbox && bin/apply`. This loses agent logins, the GitHub token, and the cargo
registry cache. Target dirs survive on the `cargo` disk; `limactl disk delete cargo` drops them too.
