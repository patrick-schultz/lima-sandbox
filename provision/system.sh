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
apt-get update
apt-get install -y --no-install-recommends \
  build-essential cmake pkg-config libssl-dev clang lld \
  gcc-x86-64-linux-gnu g++-x86-64-linux-gnu \
  git gh curl ca-certificates gnupg unzip \
  fish tmux vim ripgrep fd-find jq \
  python3 python3-venv \
  nodejs

ln -sfn "$(command -v fdfind)" /usr/local/bin/fd

# --- x86-64 runtime for Rosetta ---------------------------------------------
# Rosetta runs x86-64 ELF binaries, but they need an x86-64 dynamic loader at /lib64 and
# glibc/libstdc++ in the x86-64 multiarch dir. The cross gcc packages ship these under
# /usr/x86_64-linux-gnu/lib; ldconfig misclassifies them as AArch64, so symlink them instead.
# /lib/x86_64-linux-gnu already exists (binutils-x86-64-linux-gnu puts ldscripts there).
install -d /lib64 /lib/x86_64-linux-gnu
ln -sfn /usr/x86_64-linux-gnu/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
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
