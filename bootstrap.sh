#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Usage: bootstrap.sh [init] <host>
# Runs `sudo nixos-rebuild boot --install-bootloader --flake .#<host> -L -v` with the registry
# caches injected via --option (survives sudo, needs no trusted user).
# nixos-rebuild-ng sets NIXOS_INSTALL_BOOTLOADER itself (nix.py:716) and runs the activation
# under `env -i`, so an `env` prefix in front of sudo never reaches it — the flag does.
[ "${1:-}" != init ] || shift
host="${1:?usage: $(basename "$0") [init] <host>}"

f="modules/cache-registry.nix"
nix_opts=(--option extra-experimental-features "nix-command flakes")
urls="$(nix "${nix_opts[@]}" eval --impure --raw --file "$f" substituters)"
keys="$(nix "${nix_opts[@]}" eval --impure --raw --file "$f" trustedPublicKeys)"

# The two eval reads need the experimental features; nixos-rebuild-ng already adds
# `nix-command flakes` via its own FLAKE_FLAGS, so the rebuild line does not repeat it.
exec sudo nixos-rebuild boot --flake "$PWD#$host" -L -v --install-bootloader \
  --option extra-substituters "$urls" \
  --option extra-trusted-public-keys "$keys"
