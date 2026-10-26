#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Day-zero switch: stages the registry's binary caches before the build that needs them.
#
# urls + keys come from modules/cache-registry.nix, the only place a cache is written, so this
# script never lists a cache itself. A host whose /etc/nix/nix.conf does not carry them yet would
# otherwise compile cache-fed paths locally (CachyOS kernel, spicy niri + xwayland-satellite, the
# firmware VM). `--option` beats NIX_CONFIG: it survives sudo's env_reset and needs no trusted
# user. After the first switch /etc/nix/nix.conf carries them, so plain `nh os switch` is enough.
cache_flags=()
cache_flags_init() {
  local f="modules/cache-registry.nix"
  local urls keys
  urls="$(nix eval --impure --raw --file "$f" substituters)" || {
    echo "ERROR: cannot eval cache urls from '$f'." >&2
    return 1
  }
  keys="$(nix eval --impure --raw --file "$f" trustedPublicKeys)" || {
    echo "ERROR: cannot eval cache keys from '$f'." >&2
    return 1
  }
  cache_flags=(--option extra-substituters "$urls" --option extra-trusted-public-keys "$keys")
}

# Swap for the rebuild itself: the persistent swapfile is activated by a systemd unit that only
# runs on the *new* system's boot, so the first switch has none and OOMs. zram needs no disk and
# no filesystem (a btrfs swapfile cannot be compressed or snapshotted). Best-effort — a failure
# here costs a local build, not the switch.
prepare_swap() {
  local sudo=""
  [ "$(id -u)" -ne 0 ] && sudo="sudo"
  if [ "$(tail -n +2 /proc/swaps | wc -l)" -gt 0 ]; then
    echo "Swap already active - skipping swap preparation."
    return 0
  fi
  echo "Creating zram swap to avoid OOM during the rebuild..."
  # Inner quoting is deliberate: \$2 and "$size" are expanded by the inner bash, not here.
  # shellcheck disable=SC2016
  $sudo bash -c '
    modprobe zram
    ram_kb=$(awk "/MemTotal/ {print \$2}" /proc/meminfo)
    size=$((ram_kb / 2 * 1024)) # half of RAM, in bytes; zram is compressed, so it costs less than it swaps
    target=/sys/block/zram0/reset
    [ -w "$target" ] || target=/sys/block/zram0/disksize
    [ -w /sys/block/zram0/compression ] && echo zstd > /sys/block/zram0/compression
    echo "$size" > "$target"
    mkswap /dev/zram0 >/dev/null
    swapon -p 5 /dev/zram0
  ' || echo "WARN: zram swap setup failed - continuing anyway." >&2
}

cmd_init() {
  local target="${1:-}"
  local dry="${2:-false}"
  local mode flake_ref build_ref

  # flake_ref  -> what nixos-rebuild / home-manager take for --flake (they add the
  #               nixosConfigurations. / homeConfigurations. prefix themselves)
  # build_ref  -> the full installable `nix build` needs for --dry-run
  if [ -n "$target" ]; then
    flake_ref="$PWD#${target}"
    if [[ "$target" == *@* ]]; then
      mode="home"
      build_ref="$PWD#homeConfigurations.${target}.activationPackage"
    else
      mode="os"
      build_ref="$PWD#nixosConfigurations.${target}.config.system.build.toplevel"
    fi
  else
    # No target: pass the flake directory alone and let the tool pick the
    # host (os) or user@host / user (home) from the current machine.
    flake_ref="$PWD"
    build_ref=""
    if grep -q '^NAME="NixOS"' /etc/os-release 2>/dev/null; then
      mode="os"
    else
      mode="home"
    fi
  fi

  cache_flags_init || return 1

  if [ "$dry" = "true" ]; then
    [ -n "$build_ref" ] || {
      echo "ERROR: --dry-run needs an explicit target (host or user@host)." >&2
      return 1
    }
    # What the switch would fetch vs compile locally. Nothing is built or activated.
    echo "Dry run of '$build_ref' with the registry caches staged:"
    nix build --no-link --dry-run "$build_ref" "${cache_flags[@]}" 2>&1 | grep -vE '^copying|^\s*$' || true
    return 0
  fi

  if [ "$mode" = "os" ]; then
    prepare_swap
    echo "Switching system: $flake_ref"
    sudo nixos-rebuild switch --flake "$flake_ref" "${cache_flags[@]}" -L
  else
    echo "Switching home: $flake_ref"
    if command -v home-manager &>/dev/null; then
      home-manager switch --flake "$flake_ref" "${cache_flags[@]}" -L
    else
      # Day zero on a non-NixOS host: home-manager itself comes from its own input.
      nix run "github:nix-community/home-manager/master" -- switch --flake "$flake_ref" "${cache_flags[@]}" -L
    fi
  fi
}

help() {
  cat <<EOF
Usage: $(basename "$0") init [TARGET] [--dry-run]
       $(basename "$0") help

  init [TARGET]     Stage the cache registry, then switch. TARGET is a host name
                    (nixosConfigurations.<host>) or user@host (homeConfigurations.<user@host>).
                    Omitted: auto-detect NixOS vs non-NixOS from /etc/os-release.
    --dry-run       Report what the switch would fetch vs build locally, then stop.
                    Needs an explicit TARGET.
EOF
}

main() {
  case "${1:-}" in
  init)
    shift
    local target="" dry="false"
    while [ $# -gt 0 ]; do
      case "$1" in
      --dry-run) dry="true" ;;
      -*)
        echo "Unknown option: $1" >&2
        help >&2
        return 1
        ;;
      *) target="$1" ;;
      esac
      shift
    done
    cmd_init "$target" "$dry"
    ;;
  help) help ;;
  *)
    help >&2
    return 1
    ;;
  esac
}

main "$@"
