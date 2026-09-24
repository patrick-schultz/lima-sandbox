# lima-sandbox

A Lima VM that sandboxes coding agents (Claude Code, Codex) and cross-compiles Rust for x86_64.
The VM is the safety boundary: agents run inside it with permission prompts off, and only the
directories listed in `sandbox.yaml` are visible.

Ubuntu 24.04 arm64 under vz, 8 CPUs, 16 GiB + 8 GiB swap, 100 GiB sparse disk, Rosetta binfmt on,
no containerd.

## Layout

| Path | Purpose |
| --- | --- |
| `sandbox.yaml` | Lima template. Mounts, resources, and provision steps that reference the files below. |
| `provision/system.sh` | Root provisioning: apt packages, cross gcc, mold, gh, Node, jj, codex, pyright, swap, fish as login shell. |
| `provision/user.sh` | User provisioning: fish and jj config, rustup (nightly default + stable, x86_64 target), cargo config, uv, claude, agent config symlinks. |
| `guest/sandbox-sync` | Installed at `/usr/local/bin/sandbox-sync` in the guest. Regenerates agent config from `~/.agents`. |
| `guest/gh`, `guest/gh-token`, `guest/git-credential-sandbox` | Installed in `/usr/local/bin`, with `/usr/bin/gh` linked to the `gh` wrapper. Per-owner GitHub token selection, see below. |
| `bin/apply` | Renders the template and creates or updates the VM. Also adds the ssh `Include` on the host. |

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

## Usage

```
bin/apply                 # create, or stop + apply sandbox.yaml + start
limactl shell sandbox     # fish session in the guest
ssh lima-sandbox          # for Zed, T3 Code, or plain ssh
limactl stop sandbox
```

Mounted projects appear at their host paths, e.g. `/Users/pschulz/dev/datafusion-sandbox`.
Cargo builds go to `~/.cargo-target` in the guest, never to `target/` on the mount.

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
`RUSTFLAGS` plus a family-specific `CARGO_TARGET_DIR` under `~/.cargo-target/`. Binaries link
against glibc 2.39; if the GCE image is older, add cargo-zigbuild.

Without `RUSTFLAGS`, the project's `-Ctarget-cpu=native` resolves to the arm64 host CPU and rustc
ignores every feature for the x86 target, so you get a baseline x86-64 binary. That is fine for a
smoke test, not for a benchmark build.

The resulting binaries run directly in the VM under Rosetta, as a functional check only. Rosetta
has no AVX-512, and timings under it mean nothing.

## Rebuilding from scratch

`limactl delete sandbox && bin/apply`. This loses agent logins, the GitHub token, and the cargo cache.
