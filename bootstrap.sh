#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Usage: bootstrap.sh [init] <host>
# Runs `sudo nixos-rebuild boot --flake .#<host> -L -v` with the registry caches and the
# experimental features injected via --option (survives sudo, needs no trusted user).
[ "${1:-}" != init ] || shift
host="${1:?usage: $(basename "$0") [init] <host>}"

f="modules/cache-registry.nix"
nix_opts=(--option extra-experimental-features "nix-command flakes")
urls="$(nix "${nix_opts[@]}" eval --impure --raw --file "$f" substituters)"
keys="$(nix "${nix_opts[@]}" eval --impure --raw --file "$f" trustedPublicKeys)"

exec env NIXOS_INSTALL_BOOTLOADER=1 \
  sudo nixos-rebuild boot --flake "$PWD#$host" -L -v "${nix_opts[@]}" \
  --option extra-substituters "$urls" \
  --option extra-trusted-public-keys "$keys"
