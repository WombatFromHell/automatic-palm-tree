#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Usage: bootstrap.sh <host>                  NixOS: nixos-rebuild boot
#        bootstrap.sh <user>@<host>           non-NixOS: home-manager switch
#        bootstrap.sh --standalone [--install] [--rebind[=DIR]] [<user>@<host>]
#
# --standalone prepares a non-NixOS box first; with no target the script stops after that.
#   (default)       install Nix via the installer's `ostree` plan when `nix` is not on PATH, and
#                   make this user a trusted Nix user (else the injected caches are ignored)
#   --install       also install home-manager (channel flow)
#   --rebind[=DIR]  bind DIR on /nix instead of the planner's /var/home/nix; fresh installs only
#                   (DIR defaults to $REBIND_SRC, else /mnt/data1/nix)
rebind_src="${REBIND_SRC:-/mnt/data1/nix}"
standalone= install= rebind= target=

usage="usage: ${0##*/} <host> | <user>@<host> | --standalone [--install] [--rebind[=DIR]] [<user>@<host>] | --help"
die() {
  printf '%s\n' "$@" >&2
  exit 2
}
# `nix store info` logs to stderr; no -q on grep so nix is never SIGPIPE'd under pipefail.
trusted() { nix store info 2>&1 | grep -x 'Trusted: 1' >/dev/null; }

for a; do
  case $a in
  --standalone) standalone=1 ;;
  --install) install=1 ;;
  --rebind) rebind=1 ;;
  --rebind=*) rebind=1 rebind_src="${a#*=}"
    [ -n "$rebind_src" ] || die "--rebind needs a directory" "$usage" ;;
  --help) printf '%s\n' "$usage"; exit 0 ;;
  -*) die "unknown flag: $a" "$usage" ;;
  *)
    [ -z "$target" ] || die "extra argument: $a" "$usage"
    target=$a
    ;;
  esac
done
[ -n "$standalone" ] || [ -z "$install$rebind" ] || die "--install/--rebind require --standalone" "$usage"
[ -n "$standalone$target" ] || die "missing target" "$usage"
[ -z "$standalone" ] || [ -z "$target" ] || [[ $target == *@* ]] || die "--standalone target must be <user>@<host>" "$usage"

# --- bootstrap (non-NixOS only) ---
if [ -n "$standalone" ] && ! command -v nix >/dev/null; then
  # The ostree planner creates its `persistence` dir and bind-mounts it on /nix (nix.mount), so
  # --persistence replaces /var/home/nix outright; nothing is ever created there.
  plan=(install ostree --enable-flakes)
  [ -z "$rebind" ] || plan+=(--persistence "$rebind_src")
  curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- "${plan[@]}"
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"
fi

# Every step below (store info, channel flow, cache eval, switch) needs nix; check once, here.
# A rebind only moves the store while the installer is running; past that it would be a silently
# dropped flag, so refuse instead of pretending the bind happened.
if [ -n "$rebind" ] && command -v nix >/dev/null; then
  die "--rebind needs a fresh install (nix is already on PATH)" "$usage"
fi

command -v nix >/dev/null || die "nix is not on PATH (--standalone installs it)"

# Reaches the client-side nix calls (store info, the registry eval, home-manager). sudo's
# env_reset drops it for nixos-rebuild, which sets the flake flags itself.
export NIX_CONFIG="experimental-features = nix-command flakes"

# Untrusted users get client-side substituters/trusted-public-keys ignored, so our cache
# injection would do nothing. Trust is daemon-side: extend trusted-users, restart the daemon.
# ponytail: assumes the installer's layout (nix.conf ends with `!include nix.custom.conf`)
if [ -n "$standalone" ] && ! trusted; then
  echo "extra-trusted-users = $(id -un)" | sudo tee -a /etc/nix/nix.custom.conf >/dev/null
  sudo systemctl restart nix-daemon.service
  # Appending is only a change if /etc/nix/nix.conf !includes nix.custom.conf; check the result
  # rather than reporting a day zero that did not happen.
  trusted || die "still not a trusted nix user after restarting nix-daemon (/etc/nix/nix.conf must !include nix.custom.conf)"
fi

if [ -n "$install" ]; then
  # The release is the flake's own input, so a bump cannot leave a CLI from the old branch here.
  hm_ref="$(grep -o 'home-manager/release-[0-9.]*' flake.nix | cut -d/ -f2)"
  [ -n "$hm_ref" ] || die "flake.nix pins no home-manager release to install from"
  nix-channel --add "https://github.com/nix-community/home-manager/archive/$hm_ref.tar.gz" home-manager
  nix-channel --update
  nix-shell '<home-manager>' -A install
  # ponytail: classic profile path; newer Nix may use $XDG_STATE_HOME/nix/profile
  export PATH="$HOME/.nix-profile/bin:$PATH"
fi
[ -n "$target" ] || { echo "standalone ready: nix on PATH, $(id -un) trusted"; exit 0; }

# --- switch ---
# nixos-rebuild-ng sets NIXOS_INSTALL_BOOTLOADER itself and activates under `env -i`, so only the
# --install-bootloader flag reaches it.
if [[ $target == *@* ]]; then
  tool=home-manager
  cmd=(home-manager switch --flake "$PWD#$target")
else
  tool=nixos-rebuild
  cmd=(sudo nixos-rebuild boot --install-bootloader --flake "$PWD#$target")
fi
command -v "$tool" >/dev/null || die "$tool is not on PATH"
# NixOS builds run as root under sudo; a standalone switch runs as us.
[ "$tool" != home-manager ] || trusted || die "the nix daemon did not grant trust to $(id -un) (nix store info failed or said Trusted: 0) -- run bootstrap.sh --standalone once"

f=modules/cache-registry.nix
urls="$(nix eval --impure --raw --file "$f" substituters)"
keys="$(nix eval --impure --raw --file "$f" trustedPublicKeys)"
cache=(--option extra-substituters "$urls" --option extra-trusted-public-keys "$keys")

# A host eval is ~2.3GB of anonymous RAM in the client (DESIGN.md, "Build RAM"). MemoryHigh
# throttles first, MemoryMax kills, MemorySwapMax bounds any spill; the build itself runs in the
# nix-daemon outside this scope. The pid in the unit name avoids "already loaded" after an OOM.
# A socket can exist with no user systemd behind it, so probe instead of assuming.
scope=()
if systemd-run --user --scope -q --expand-environment=no --unit="flakeroot-probe-$$.scope" true >/dev/null 2>&1; then
  scope=(systemd-run --user --scope -q --expand-environment=no --unit="flakeroot-rebuild-$$.scope"
    -p MemoryHigh=2600M -p MemoryMax=3072M -p MemorySwapMax=1024M)
fi

exec "${scope[@]}" "${cmd[@]}" -L -v "${cache[@]}"
