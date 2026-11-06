#!/usr/bin/env bash
# install.sh — staged installer for a host whose drive this flake owns alone.
#
#   prepare    read-only: host + drive checks, temporary zram, partition-table checksum
#   terraform  disko create/format/mount under --root, so the target store lands on the disk
#   deploy     nixos-install --root <dir>: the closure builds into <dir>/nix/store and the boot
#            loader is written (nixos-install runs switch-to-configuration boot itself)
#   reboot     only after deploy
#
# Every destructive step is confirmed one at a time, never as a blanket yes. --force or
# INSTALL_FORCE=1 is the testing override; --dry-run runs nothing. `destroy` and
# --yes-wipe-all-disks are never passed: a partition another OS owns is never a target.
set -euo pipefail
cd "$(dirname "$0")"

root="/mnt"
host=""
stage="all"
dry=0
force="${INSTALL_FORCE:-0}"
# The ISO's /nix/store has no room and Nix refuses a store under a world-writable /tmp, so the
# evals and the disko script go to a store under /run (tmpfs, 755).
scratch="${INSTALL_SCRATCH:-/run/flakeroot-scratch}"
# Installer ISOs differ in what their nix.conf enables, and the flake commands here need both.
export NIX_CONFIG="experimental-features = nix-command flakes"

usage() {
  printf 'usage: install.sh [--dry-run] [--force] [--root <dir>] [--scratch <dir>] [--stage prepare|terraform|deploy|reboot|all] <host>\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) dry=1 ;;
  --force) force=1 ;;
  --root)
    root="$2"
    shift
    ;;
  --scratch)
    scratch="$2"
    shift
    ;;
  --stage)
    stage="$2"
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  -*)
    printf 'install.sh: unknown flag %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  *) host="$1" ;;
  esac
  shift
done

if [ -z "$host" ]; then
  usage >&2
  exit 2
fi

case "$stage" in
prepare | terraform | deploy | reboot | all) ;;
*)
  printf 'install.sh: unknown stage %s\n' "$stage" >&2
  exit 2
  ;;
esac

say() { printf '%s\n' "$*"; }

# One destructive step, one answer. Without a terminal there is nobody to ask, so the step is
# refused rather than assumed.
confirm() {
  if [ "$dry" = 1 ]; then
    say "[dry-run] $1"
    return 0
  fi
  if [ "$force" = 1 ]; then
    say "$1 (forced)"
    return 0
  fi
  if [ ! -t 0 ]; then
    say "refused: $1 needs a confirmation and there is no terminal (use --force or INSTALL_FORCE=1)"
    return 2
  fi
  printf 'confirm [y/N]: '
  read -r answer
  if [ "$answer" != "y" ]; then
    say "not confirmed: nothing done"
    return 2
  fi
}

run() {
  if [ "$dry" = 1 ]; then
    say "[dry-run] $*"
    return 0
  fi
  "$@"
}

# Same wrap bootstrap.sh uses: the build is what spills memory, so that is what gets capped.
# Same wrap bootstrap.sh uses: the build is what spills memory, so that is what gets capped. No
# --unit: systemd names each transient scope, and a name we reuse is refused outright.
scope_base=(systemd-run --user --scope -q --expand-environment=no -p MemoryHigh=2600M
  -p MemoryMax=3072M -p MemorySwapMax=1024M)
if ! systemd-run --user --scope -q --expand-environment=no true >/dev/null 2>&1; then
  scope_base=()
fi

scoped() {
  if [ "${#scope_base[@]}" = 0 ]; then
    "$@"
    return
  fi
  "${scope_base[@]}" "$@"
}

attr() { printf '.#nixosConfigurations.%s.config' "$host"; }

# The admins are whoever the host puts in wheel — flakeHost.adminUsernames is what puts them there
# (modules/defaults/nixos.nix), so read that rather than guessing a name.
admins() {
  scoped nix eval --store "$scratch" --impure --raw "$(attr).flakeHost.adminUsernames" \
    --apply 'xs: builtins.concatStringsSep " " xs' 2>/dev/null || true
}

# What the drive looks like right now: first 2MB holds the partition table.
table_checksum() { dd if="$device" bs=1M count=2 status=none | md5sum | cut -d' ' -f1; }

# The layout, the drive, and the one fact that makes a layout legal here at all.
resolve() {
  if [ ! -f flake.nix ]; then
    say "install.sh: no flake.nix in $(pwd) — put the flake here first"
    exit 2
  fi
  # The ISO's /nix/store is an overlay whose upper half is a tiny tmpfs, so every eval and build
  # below goes to its own store instead: the ISO's /nix/store cannot hold even a fetched flake.
  if [ "$dry" != 1 ]; then
    mkdir -p "$scratch"
    # Nix refuses a world-writable store path, and the ISO's umask leaves 777 on a fresh dir.
    # /run is 2G and the ISO's own /nix/store upper tmpfs is already full, so the scratch store gets
    # a tmpfs of its own — disko's closure fits nowhere else on the ISO. If the mount is refused the
    # plain directory is still usable.
    if ! findmnt -n -o TARGET "$scratch" >/dev/null 2>&1; then
      mount -t tmpfs -o size=2G tmpfs "$scratch" || true
    fi
    # A fresh tmpfs root is 1777, which Nix refuses; the directory itself is 777 under the ISO umask.
    chmod 755 "$scratch"
  fi
  owned=$(scoped nix eval --store "$scratch" --impure "$(attr).flakeHost.ownsWholeDisk") || exit 2
  if [ "$owned" != "true" ]; then
    say "$host: ownsWholeDisk is false — its drive is shared with another OS, so no layout may be written here"
    exit 2
  fi
  device=$(scoped nix eval --store "$scratch" --impure --raw "$(attr).disko.devices.disk" \
    --apply 'd: (builtins.head (builtins.attrValues d)).device') || exit 2
  # lsblk lists the drive and each partition on it; only the drive's own line says whether this
  # machine has the whole disk to own. An installed drive (partitions present) is adoptable.
  if [ "$(lsblk -n -o TYPE "$device" 2>/dev/null | head -1)" != "disk" ]; then
    say "$host: $device is not a whole disk on this machine"
    exit 2
  fi
}

# The ISO lives in RAM, and the closure build is what overflows it. zram is RAM too, but it is
# compressed, so the build's spill goes there instead of onto a disk nobody formatted. It is added
# whenever it is missing, not only when RAM looks short at the moment of the check: the pressure
# arrives mid-build, after the free-space reading.
add_zram() {
  if [ -n "$(lsblk -n -o TYPE /dev/zram0 2>/dev/null)" ]; then
    return
  fi
  avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  confirm "only $((avail / 1024 / 1024))GB of RAM free on the ISO: add a 2GB zram swap device (memory only, no disk write)"
  run modprobe zram
  # disksize is a sysfs knob; writing /dev/zram0 hits ENOSPC and leaves the device uninitialised.
  printf 2G | run tee /sys/block/zram0/disksize
  run mkswap /dev/zram0
  run swapon /dev/zram0
}

prepare() {
  resolve
  before=$(table_checksum)
  say "$host: drive $device, layout owned by disko, mounts under $root"
  add_zram
  after=$(table_checksum)
  if [ "$before" != "$after" ]; then
    say "prepare changed the partition table ($before -> $after) — that must never happen"
    exit 2
  fi
  say "prepare ok: partition table unchanged ($after)"
}

terraform() {
  resolve
  mode="create,format,mount"
  if findmnt -n -o SOURCE "$root/nix" >/dev/null 2>&1; then
    mode="mount"
    say "$root/nix is already mounted — the layout is adopted, not rebuilt"
  else
    confirm "partition table, filesystems and subvolumes on $device: everything currently on it is destroyed"
  fi
  if [ "$dry" = 1 ]; then
    say "[dry-run] nix build --store $scratch --no-link --print-out-paths $(attr).system.build.diskoScript"
    script="$scratch/dry-run"
  else
    # A store outside /nix/store keeps its paths under <store>/nix/store while nix prints the
    # canonical /nix/store form, and the out path can be a symlink to another canonical path — both
    # have to be re-rooted into the scratch store to be runnable.
    out=$(scoped nix build --store "$scratch" --no-link --print-out-paths \
      "$(attr).system.build.diskoScript") || {
      say "terraform: the disko script did not build (scratch store out of space?)"
      exit 2
    }
    script="$scratch$out"
    if [ -L "$script" ]; then
      script="$scratch$(readlink "$script")"
    fi
    if [ -d "$script" ]; then
      script="$script/bin/disko"
    fi
  fi
  # No --yes-wipe-all-disks: the script is what asks, and it is what refuses a disk it does not own.
  # The stage's own contract is the mount, so a disko failure surfaces as the missing mount.
  run "$script" --mode "$mode" || say "disko reported a failure"
  src=$(findmnt -n -o SOURCE "$root/nix" 2>/dev/null) || {
    say "terraform did not leave a disk-backed $root/nix — deploy cannot run"
    exit 2
  }
  say "terraform ok: $root/nix mounted from $src"
}

deploy() {
  resolve
  if ! findmnt -n -o SOURCE "$root/nix" >/dev/null 2>&1; then
    say "deploy needs terraform first: $root/nix is not a real filesystem mount"
    exit 2
  fi
  confirm "install $host onto $root: the closure builds into $root/nix/store and the boot loader is written"
  # nixos-install only trusts `auto?trusted=1`, which trusts caches the client already knows. The
  # registry caches have to reach the build as client options, so they go through NIX_CONFIG.
  urls=$(nix eval --store "$scratch" --impure --raw --file modules/cache-registry.nix substituters)
  # The build that nixos-install is about to start is the thing that overflows the ISO's RAM.
  add_zram
  keys=$(nix eval --store "$scratch" --impure --raw --file modules/cache-registry.nix trustedPublicKeys)
  export NIX_CONFIG="experimental-features = nix-command flakes
extra-substituters = $urls
extra-trusted-public-keys = $keys"
  run scoped nixos-install --flake ".#$host" --root "$root" --no-root-passwd
  # Nothing sets a password (--no-root-passwd), so the installer's ssh keys are the only way into
  # the new system. They belong to the users this host declares, not to whoever ran the ISO, and
  # under sudo $HOME is root's, so the keys come from whoever invoked the installer.
  users=$(scoped nix eval --store "$scratch" --impure --raw "$(attr).flakeHost.osUsernames" \
    --apply 'xs: builtins.concatStringsSep " " xs') || exit 2
  key_src=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)/.ssh/authorized_keys
  if [ -s "$key_src" ]; then
    for u in $users; do
      install -D -m 600 "$key_src" "$root/home/$u/.ssh/authorized_keys"
      # The ISO has no account for the installed user, so ownership is taken from the installed
      # system's own passwd as uid:gid.
      chown -R "$(grep "^$u:" "$root/etc/passwd" | cut -d: -f3,4)" "$root/home/$u/.ssh"
    done
    say "ssh keys from $key_src installed for: $users"
  fi
  # The admins are whoever the host puts in wheel (flakeHost.adminUsernames, modules/defaults).
  admins=$(admins)
  if [ -z "$admins" ]; then
    say "deploy found no wheel user in $host's config — the design needs at least one admin"
    exit 2
  fi
  # nixos-install --no-root-passwd leaves root and every admin with nothing to log in with, and the
  # freshly installed system has no /run/current-system yet, so passwd must come from its own store.
  # The freshly installed tree has no /run/current-system yet, so the installer environment's own
  # nixos-enter is what gives a command inside it a working PATH.
  how="nixos-enter --root $root --"
  # Only a real terminal can answer a password prompt; --force must never block on one.
  for a in root $admins; do
    if [ -t 0 ] && confirm "set a password for $a now (prompts twice, no current password needed)"; then
      run nixos-enter --root "$root" -- passwd "$a"
      say "password set for $a"
    else
      say "no password set for $a — run \`$how passwd $a\` before reboot, nothing sets a password"
    fi
  done
  say "deploy ok: $host installed on $root, boot loader written — reboot once root and an admin have passwords"
}

# A password exists when the installed system's shadow has a real hash for the account: field 2 is
# neither empty nor the '!'/'*' placeholders nixos-install leaves behind.
has_password() {
  grep -qE "^$1:[^!*:]+:" "$root/etc/shadow"
}

reboot_stage() {
  # Rebooting into a system nobody can log into is not a finish, so the installed system's own
  # shadow is the proof — root plus at least one admin must have a real password.
  if ! has_password root; then
    say "refused: no password for root — run \`chroot $root passwd root\` first"
    exit 2
  fi
  list=$(admins)
  if [ -z "$list" ]; then
    say "refused: $host declares no wheel user, so there is no admin whose password can be checked"
    exit 2
  fi
  for a in $list; do
    if ! has_password "$a"; then
      say "refused: no password for $a — run \`chroot $root passwd $a\` first"
      exit 2
    fi
  done
  confirm "reboot into the freshly installed system"
  run reboot
}

case "$stage" in
prepare) prepare ;;
terraform) terraform ;;
deploy) deploy ;;
reboot) reboot_stage ;;
all)
  prepare
  terraform
  deploy
  reboot_stage
  ;;
esac
