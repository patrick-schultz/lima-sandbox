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
| `provision/user.sh` | User provisioning: fish and jj config, rustup (nightly default + stable, x86_64 target), cargo config, cargo wrapper link, kache and its daemon, cargo-binstall, cargo-nextest, uv, claude, npm user prefix, humanlayer CLI and its daemon unit, agent config symlinks. |
| `guest/sandbox-sync` | Installed at `/usr/local/bin/sandbox-sync` in the guest. Regenerates agent config from `~/.agents`. |
| `guest/sandbox-cargo`, `guest/sandbox-gc-targets` | Installed in `/usr/local/bin`, with `~/.local/bin/cargo` linked to the wrapper. Per-cargo-workspace target dirs, see below. |
| `guest/jj-adopt-worktree` | Installed in `/usr/local/bin`, and linked at `~/.local/bin` on the host by `bin/apply`. Adopts tool-made git worktrees as jj workspaces, see below. |
| `guest/gh`, `guest/gh-token`, `guest/git-credential-sandbox` | Installed in `/usr/local/bin`, with `/usr/bin/gh` linked to the `gh` wrapper. Per-owner GitHub token selection, see below. |
| `bin/apply` | Renders the template and creates or updates the VM. Adds a workspaces mount per project, creates the `cargo` disk, and adds the ssh `Include` on the host. |

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

Mounted projects appear at their host paths, e.g. `/Users/pschulz/dev/datafusion-sandbox`, and so do
their workspaces under `/Users/pschulz/dev/workspaces/`. Cargo builds go to a per-cargo-workspace dir
under `/mnt/lima-cargo/target`, never to `target/` on the mount.

### Adding a project

Add a `mounts` entry to `sandbox.yaml`, add a `[projects."..."]` trust entry to
`~/.agents/codex/config-sandbox.toml`, and run `bin/apply`. This repo is deliberately not mounted.
`bin/apply` also mounts the project's workspaces dir, and the project's trust entry covers them.

### Workspaces

A project's jj workspaces live at `~/dev/workspaces/<project>/<name>` on the host, whoever creates
them. For every writable `~/dev/<project>` mount, `bin/apply` creates `~/dev/workspaces/<project>`
and mounts it writable, so a project's workspaces are visible exactly when the project is.
Workspaces of other repos can live in `~/dev/workspaces` too; the sandbox never sees them.

Workspaces are colocated: each is a jj workspace and a git worktree. `jj workspace add` makes them
so in a colocated repo since jj 0.46. Codex resolves a git worktree to its main checkout for trust,
so the project's trust entry covers its workspaces.

T3 Code and Zed create plain git worktrees. `jj-adopt-worktree [PATH]` turns one into a workspace,
keeping the checkout and any edits as the working-copy commit on top of git HEAD.

- It moves the worktree aside, lets jj create the workspace there with empty sparse patterns,
  moves the `.jj` in, and runs `jj sparse reset`, which keeps every file that already differs. The
  worktree is missing for a moment, so adopt before an agent starts working in it. If
  [jj-vcs/jj#9943](https://github.com/jj-vcs/jj/pull/9943) lands, `jj git worktree adopt` replaces it.
- T3 Code: set Settings → Storage → Worktree location to `~/dev/workspaces` on the host and in the
  sandbox. T3 puts worktrees at `<location>/<repo>/<branch>`. The setting needs T3 0.0.46 or a
  nightly from Oct 6, 2026 on; before that, worktrees go to `~/.t3/worktrees` on each machine. In each project, add an action
  (nightly: pick the project in the "Applying settings for" line at the top of Settings, then
  Projects → Actions) with command `jj-adopt-worktree`, "Run automatically on worktree creation"
  and "Wait for it to finish before the agent starts". It runs in the new worktree. Add a second
  action with command `jj-adopt-worktree --park` and "Run in the thread's worktree when the thread
  settles"; see Parking below.
- Other tools: agents adopt a worktree themselves when they find a `.git` file and no `.jj`, per
  `~/.agents/AGENTS.md`.
- Branches: once an agent commits with jj, git HEAD is detached and the tool's branch, such as
  `t3/...`, stays behind. Agents move it onto the change they push and push it under that name, so
  T3 still finds the PR by branch name. T3's Commit, Push, and PR buttons refuse a detached HEAD.
- Parking: T3's worktree cleanup keeps every worktree an agent worked in, because jj either
  detaches git HEAD or leaves the work as uncommitted changes in git's view. `jj-adopt-worktree
  --park [PATH]` removes a workspace instead. It moves the tool's branch forward onto the work (`@`,
  or `@-` when `@` is empty and undescribed), removes the worktree, and forgets the workspace.
  Adopting records the branch in the repo's git config as `branch.<branch>.jj-workspace = <path>`,
  which `git branch -m` carries along. T3 creates every worktree on a temporary `t3/<hash>` branch
  and renames it once a name is generated, usually after adoption, whatever its branch naming
  setting. `jj-adopt-worktree --branch [PATH]` prints the recorded branch, falling back to the one
  git HEAD is on. When a parked T3 thread resumes, T3 recreates
  the worktree from the branch, and the agent adopts it again, with the work in `@-`. Merging a PR
  settles its thread, and a fetch that sees the branch deleted abandons the work and leaves the
  workspace stale; parking then updates it and only removes it, since the work is in trunk. Parking
  refuses when the branch has moved somewhere that is not an ancestor of the work, or when a stale
  workspace had edits jj had not recorded, and leaves the workspace in place. Nothing is pushed. Ignored files in the worktree, such as `.env`, are deleted.
- Removing a worktree leaves its jj workspace behind. `jj-adopt-worktree --gc [REPO]` forgets
  workspaces whose directory is gone but whose parent exists. It runs after each adoption, and at
  boot for every mounted repo.

### First run, once per VM

1. `limactl shell sandbox`
2. `claude` and follow the login flow.
3. `codex login` and follow the device flow.
4. For each repo owner you work under, create a fine-grained GitHub token for that owner,
   limited to the repos you mount, with Contents, Issues, and Pull requests read/write.
   Then in the VM: `gh-token add <owner>` and paste it.
5. `humanlayer login` and follow the device flow, then `systemctl --user start humanlayer-daemon`.
   Skip this if you don't use HumanLayer.

These logins and tokens are the only credentials in the VM.

### HumanLayer daemon

The HumanLayer app runs agent sessions in the VM through a daemon. Its sessions see only the
mounted directories, like any other agent here.

- Ignore the app's `npm install -g … daemon launch --launch-token …` command. Its launch token
  expires within a day and is not stored, so a daemon started that way stops for good with the
  shell. The app's sessions run on the daemon from `humanlayer login` instead.
- The `humanlayer-daemon.service` user unit runs `humanlayer daemon launch` on the stored login in
  `~/.humanlayer/riptide/`. It starts at boot only when that login exists. `humanlayer logout`
  removes it; stop the unit too.
- The login is used only when the daemon starts: at boot, after a crash, or after a self-update.
  Each start refreshes and saves it, and a running daemon does not need it again. Logging in again
  is needed only when a start finds the refresh token no longer works, for example after the VM
  has been off for a long time. HumanLayer's WorkOS settings decide how long that is. The daemon
  then logs "Not logged in" and keeps restarting. Run `humanlayer login`, then
  `systemctl --user restart humanlayer-daemon`.
- The daemon updates itself with `npm install -g`, then exits for systemd to restart it. That is
  why `user.sh` points the user's npm prefix at `~/.local`: the system prefix `/usr` is root-only.
- `journalctl --user -u humanlayer-daemon -f` shows its log.

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

The wrapper writes the cargo workspace path to `.workspace` in each dir. `sandbox-gc-targets` runs
at boot and deletes dirs whose cargo workspace is gone, such as removed workspaces; `-n` lists them
without deleting. It keeps a dir when the cargo workspace's parent is also missing, as with an
unmounted project.

`/mnt/lima-cargo` is the `cargo` Lima disk: sparse, XFS with reflinks, and kept by
`limactl delete`. `limactl disk resize cargo --size <N>GiB` grows it while the VM is stopped.

For rust-analyzer, set `cargo.targetDir = true` in the editor or project config. It then checks
into a `rust-analyzer` subdir and does not wait on the build-dir lock behind agent builds.

### Build cache

[kache](https://github.com/kunobi-ninja/kache) is cargo's `rustc-wrapper`, so per-cargo-workspace
target dirs do not mean rebuilding every dependency. Its keys ignore the checkout path, so a fresh
workspace fills from the other workspaces' outputs. On datafusion-sandbox a fresh workspace's
first `nextest --no-run` takes 39 s instead of 202 s. The store is `/mnt/lima-cargo/kache`, on the
same XFS disk as the target dirs, so restores are reflink clones. It is capped at 60 GiB.

- `user.sh` pins the version and sha256. Bump both together, deliberately.
- `cache_executables = false`: storing each relinked 700–800 MB test binary slowed concurrent edit
  loops more every round, and mold relinks them in about a second.
- The `kache.service` user unit runs the daemon. It seeds new target dirs, runs GC, and removes
  target dirs whose cargo workspace was deleted at least a day ago.
- `KACHE_DISABLED=1` bypasses it for one command. Hardlinked outputs are read-only, so use a
  separate target dir (`SANDBOX_TARGET_SUFFIX=nokache`) for builds without kache.
- `kache stats --last-build`, `kache doctor`, `kache targets`. doctor's "Link layout: EXDEV"
  warning is a false alarm here: it compares against the cargo workspace on the mount, not
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
