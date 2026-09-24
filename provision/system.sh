#!/bin/bash
# System provisioning. Runs as root on every boot; everything here must be idempotent.
set -eux -o pipefail
export DEBIAN_FRONTEND=noninteractive

USER_NAME="{{.User}}"
JJ_VERSION="0.45.1"

# --- apt repositories -------------------------------------------------------
install -d -m 0755 /etc/apt/keyrings

if [ ! -f /etc/apt/sources.list.d/github-cli.list ]; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
fi

# Node LTS from NodeSource: needed by T3 Code's remote server, ccstatusline, and npm-installed tools.
if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
fi

# --- packages ---------------------------------------------------------------
# The gh package installs to /usr/bin/gh.real, so /usr/bin/gh can be the per-owner token wrapper.
# Putting the wrapper first on PATH is not enough: Zed starts agents with /usr/bin at the front.
# The diversion must exist before apt installs gh, and it survives gh upgrades.
dpkg-divert --local --rename --divert /usr/bin/gh.real --add /usr/bin/gh

apt-get update
apt-get install -y --no-install-recommends \
  build-essential cmake pkg-config libssl-dev clang lld mold \
  gcc-x86-64-linux-gnu g++-x86-64-linux-gnu \
  git gh curl ca-certificates gnupg unzip \
  fish tmux vim ripgrep fd-find jq \
  python3 python3-venv \
  nodejs

ln -sfn "$(command -v fdfind)" /usr/local/bin/fd
ln -sfn /usr/local/bin/gh /usr/bin/gh

# Cargo's `linker` setting takes a program, not arguments, so these wrappers select mold.
# Setting the linker this way, rather than in rustflags, survives a RUSTFLAGS override and
# leaves each project's own rustflags alone. The cross gcc looks for a target-prefixed
# ld.mold under -fuse-ld=mold, so it gets mold's `ld` directory with -B instead.
printf '#!/bin/sh\nexec cc -fuse-ld=mold "$@"\n' > /usr/local/bin/cc-mold
printf '#!/bin/sh\nexec x86_64-linux-gnu-gcc -B/usr/libexec/mold "$@"\n' > /usr/local/bin/x86_64-linux-gnu-cc-mold
chmod 755 /usr/local/bin/cc-mold /usr/local/bin/x86_64-linux-gnu-cc-mold

# --- swap ---------------------------------------------------------------------
# Parallel links of large test binaries can briefly exceed guest memory. Swap turns that into
# a slowdown instead of the OOM killer taking out ld or rust-analyzer.
if [ ! -f /swapfile ]; then
  fallocate -l 8G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
fi
swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile

# --- x86-64 runtime for Rosetta ---------------------------------------------
# Rosetta runs x86-64 ELF binaries, but they need an x86-64 dynamic loader at /lib64 and
# glibc/libstdc++ in the x86-64 multiarch dir. The cross gcc packages ship these under
# /usr/x86_64-linux-gnu/lib; ldconfig misclassifies them as AArch64, so symlink them instead.
# /lib/x86_64-linux-gnu already exists (binutils-x86-64-linux-gnu puts ldscripts there).
# /lib64 must be a symlink into /usr, as on amd64 Ubuntu: a real /lib64 directory makes the
# systemd and udev packages refuse to upgrade because the system is no longer merged-/usr.
install -d /usr/lib64 /lib/x86_64-linux-gnu
if [ -d /lib64 ] && [ ! -L /lib64 ]; then
  rm -rf /lib64
fi
ln -sfn usr/lib64 /lib64
ln -sfn /usr/x86_64-linux-gnu/lib/ld-linux-x86-64.so.2 /usr/lib64/ld-linux-x86-64.so.2
for f in /usr/x86_64-linux-gnu/lib/*.so*; do
  ln -sfn "$f" "/lib/x86_64-linux-gnu/$(basename "$f")"
done

# --- jj -----------------------------------------------------------------------
if ! command -v jj >/dev/null || [ "$(jj --version | awk '{print $2}')" != "$JJ_VERSION" ]; then
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
    | tar -xz -C "$tmp"
  install -m 0755 "$tmp/jj" /usr/local/bin/jj
  rm -rf "$tmp"
fi

# --- global npm tools ---------------------------------------------------------
# Codex CLI, and pyright for Claude Code's pyright-lsp plugin.
command -v codex >/dev/null || npm install -g @openai/codex
command -v pyright-langserver >/dev/null || npm install -g pyright

# --- login shell --------------------------------------------------------------
if [ "$(getent passwd "$USER_NAME" | cut -d: -f7)" != "/usr/bin/fish" ]; then
  chsh -s /usr/bin/fish "$USER_NAME"
fi
