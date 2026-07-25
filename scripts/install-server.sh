#!/usr/bin/env bash
# Install the matching relay-server binary on one SSH host.
#
# Usage: scripts/install-server.sh HOST
# HOST is any destination accepted by ssh (a Host alias is recommended, so
# connection options continue to live in ~/.ssh/config).

set -euo pipefail

usage() {
  printf 'Usage: %s HOST\n' "${0##*/}" >&2
  exit "${1:-2}"
}

if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then
  usage 0
elif [[ $# -ne 1 ]]; then
  usage
fi

host=$1
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
server_dir="$repo_dir/server"

if [[ ! -f "$server_dir/Cargo.toml" ]]; then
  printf 'error: cannot find server/Cargo.toml relative to this script\n' >&2
  exit 1
fi

if command -v rustup >/dev/null 2>&1; then
  rustup_bin=$(command -v rustup)
elif [[ -x "$HOME/.cargo/bin/rustup" ]]; then
  rustup_bin="$HOME/.cargo/bin/rustup"
else
  printf 'error: rustup is required for the supported cross-compilation targets\n' >&2
  exit 1
fi

read -r remote_os remote_arch extra < <(ssh "$host" 'uname -s -m')
if [[ -z ${remote_os:-} || -z ${remote_arch:-} || -n ${extra:-} ]]; then
  printf 'error: expected "uname -s -m" from %s, got an unsupported response\n' "$host" >&2
  exit 1
fi

target=''
linker_name=''
linker_env=''
case "$remote_os:$remote_arch" in
  Linux:x86_64)
    target=x86_64-unknown-linux-musl
    linker_name=x86_64-linux-musl-gcc
    linker_env=CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER
    ;;
  Linux:aarch64 | Linux:arm64)
    target=aarch64-unknown-linux-musl
    linker_name=aarch64-linux-musl-gcc
    linker_env=CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER
    ;;
  Darwin:arm64)
    target=aarch64-apple-darwin
    ;;
  Darwin:x86_64)
    target=x86_64-apple-darwin
    ;;
  *)
    printf 'error: unsupported remote platform from %s: %s %s\n' \
      "$host" "$remote_os" "$remote_arch" >&2
    exit 1
    ;;
esac

if ! "$rustup_bin" target list --toolchain stable --installed | grep -Fqx "$target"; then
  printf 'Installing Rust target %s…\n' "$target"
  "$rustup_bin" target add --toolchain stable "$target"
fi

linker=''
if [[ -n $linker_name ]]; then
  if command -v "$linker_name" >/dev/null 2>&1; then
    linker=$(command -v "$linker_name")
  elif command -v brew >/dev/null 2>&1; then
    musl_cross_prefix=$(brew --prefix musl-cross 2>/dev/null || true)
    if [[ -n $musl_cross_prefix && -x "$musl_cross_prefix/bin/$linker_name" ]]; then
      linker="$musl_cross_prefix/bin/$linker_name"
    fi
  fi
  if [[ -z $linker ]]; then
    printf 'error: %s is required to build %s (install Homebrew musl-cross)\n' \
      "$linker_name" "$target" >&2
    exit 1
  fi
fi

printf 'Building relay-server for %s (%s %s)…\n' "$target" "$remote_os" "$remote_arch"
if [[ -n $linker ]]; then
  (
    cd "$server_dir"
    env "$linker_env=$linker" "$rustup_bin" run stable cargo build --release --target "$target"
  )
else
  (
    cd "$server_dir"
    "$rustup_bin" run stable cargo build --release --target "$target"
  )
fi

binary="$server_dir/target/$target/release/relay-server"
if [[ ! -x $binary ]]; then
  printf 'error: build did not produce an executable at %s\n' "$binary" >&2
  exit 1
fi

remote_dir='.cache/relay'
remote_name=relay-server
temporary_name="$remote_name.tmp.$$"

printf 'Installing on %s…\n' "$host"
ssh "$host" 'mkdir -p "$HOME/.cache/relay"'
scp "$binary" "$host:~/$remote_dir/$temporary_name"
ssh "$host" "chmod 755 \"\$HOME/$remote_dir/$temporary_name\" && mv -f \"\$HOME/$remote_dir/$temporary_name\" \"\$HOME/$remote_dir/$remote_name\""
# With stdin already closed the server should immediately shut down.  This is
# a cheap executable/architecture check, stronger than merely testing its mode.
ssh "$host" 'exec "$HOME/.cache/relay/relay-server" </dev/null'

printf 'Installed %s on %s at ~/.cache/relay/relay-server\n' "$target" "$host"
