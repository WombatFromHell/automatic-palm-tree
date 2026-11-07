#!/usr/bin/env bash
# install.sh — staged installer for a host, on a drive this flake owns alone or shares.
#
#   prepare    read-only: host + drive checks, temporary zram, partition-table checksum
#   terraform  ./terraform.sh reproduces the host's layout onto the drive: a drive we own gets a
#            fresh gpt table from hosts/<host>/terraform.json; a drive we share adopts the
#            partitions the host declares. Either way the target store lands on the disk.
#   deploy     nixos-install --root <dir>: the closure builds into <dir>/nix/store and the boot
#            loader is written (nixos-install runs switch-to-configuration boot itself)
#   reboot     only after deploy
#
# Every destructive step is confirmed one at a time, never as a blanket yes. --force or
# INSTALL_FORCE=1 is the testing override; --dry-run runs nothing. `destroy` and
# --yes-wipe-all-disks are never passed: a partition another OS owns is never a target.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/confirm.sh
. lib/confirm.sh

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

# What the drive looks like right now. Only the first megabyte: the partition table lives there, and
# a partition that starts at sector 2048 starts exactly where that window ends, so formatting one is
# not a table change (ADR-b77ec913151f).
table_checksum() { dd if="$device" bs=1M count=1 status=none | md5sum | cut -d' ' -f1; }

# The precondition deploy needs: a store on the target disk, not in the ISO's RAM. terraform.sh
# mounts the root subvolume at $root, so the store is a directory inside that filesystem -- findmnt
# answers for a mountpoint, never for a directory inside one, so both placements are checked. A tmpfs
# source is refused.
store_mount() {
  local src
  src=$(findmnt -n -o SOURCE "$root/nix" 2>/dev/null || true)
  if [ -z "$src" ]; then
    src=$(findmnt -n -o SOURCE "$root" 2>/dev/null || true)
  fi
  case "$src" in
  /dev/*) printf '%s\n' "$src" ;;
  *) return 1 ;;
  esac
}

# The drive the host deploys onto, in the order the facts arrive: the drive holding the partition
# the host's mount names; the drive holding a partition that already carries the declared
# filesystem; then the one non-removable drive here. Blank partitions name nothing until
# terraform.sh formats them, which is why the last step exists — and two candidates is refused,
# never guessed (ADR-b77ec913151f).
target_disk() {
  local cand disks="" name type rm
  cand=$(lsblk -n -o PKNAME "$root_device" 2>/dev/null | head -1 || true)
  if [ -n "$cand" ]; then
    device="/dev/$cand"
    return
  fi
  cand=$(blkid -o device -t "TYPE=$root_fs" 2>/dev/null | head -1 || true)
  if [ -n "$cand" ]; then
    cand=$(lsblk -n -o PKNAME "$cand" 2>/dev/null | head -1 || true)
    if [ -n "$cand" ]; then
      device="/dev/$cand"
      return
    fi
  fi
  # Only a real drive is a target: the install ISO presents as loop/rom devices (one of them
  # removable), and the zram device this script may have just made is memory, never a disk. PTTYPE is
  # not asked for — lsblk leaves it blank and collapses the columns — and terraform.sh is what
  # refuses a drive with no partition table. No awk: the suite stubs awk for the meminfo parse.
  while read -r name type rm; do
    if [ "$type" = disk ] && [ "$rm" != 1 ] && [ "/dev/$name" != /dev/zram0 ]; then
      disks="${disks:+$disks }/dev/$name"
    fi
  done < <(lsblk -n -o NAME,TYPE,RM --nodeps)
  if [ -z "$disks" ] || [[ $disks == *" "* ]]; then
    say "$host: cannot tell which drive to adopt${disks:+ (candidates: $disks)} — terraform.sh never formats a drive by guess"
    exit 2
  fi
  device="$disks"
}

# The layout, the drive, and the one fact that decides which tool may touch it.
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
    # a tmpfs of its own — a host config's eval fits nowhere else on the ISO. If the mount is
    # refused the plain directory is still usable.
    if ! findmnt -n -o TARGET "$scratch" >/dev/null 2>&1; then
      mount -t tmpfs -o size=2G tmpfs "$scratch" || true
    fi
    # A fresh tmpfs root is 1777, which Nix refuses; the directory itself is 777 under the ISO umask.
    chmod 755 "$scratch"
  fi
  # One eval, five facts: who may partition the drive, what the host's mounts name, and whether the
  # host still declares a disko layout. Evaluating the config once is cheaper than three narrowed
  # evals of it, and the ISO's /nix/store is an overlay whose upper half is a tiny tmpfs, so every
  # eval and build below goes to its own store instead.
  facts=$(scoped nix eval --store "$scratch" --impure --raw "$(attr)" \
    --apply 'c: builtins.concatStringsSep "\n" [
      (builtins.toString c.flakeHost.ownsWholeDisk)
      (c.fileSystems."/".device or "")
      (c.fileSystems."/".fsType or "")
      (c.fileSystems."/boot".device or "")
      (builtins.concatStringsSep " " (builtins.attrNames (c.disko.devices or {})))
    ]') || exit 2
  owned=$(printf '%s\n' "$facts" | sed -n 1p)
  # `builtins.toString` of a bool is 1/0; the recipe's `owns` is true/false, so both sides are put
  # in one form before they are compared.
  case "$owned" in
  1) owned=true ;;
  0) owned=false ;;
  esac
  root_device=$(printf '%s\n' "$facts" | sed -n 2p)
  root_fs=$(printf '%s\n' "$facts" | sed -n 3p)
  esp_device=$(printf '%s\n' "$facts" | sed -n 4p)
  disko=$(printf '%s\n' "$facts" | sed -n 5p)
  # terraform.sh is the only thing this script lets touch a drive (ADR-b77ec913151f), so a host
  # declaring a disko layout has no installer to run it: that layout would be silently skipped.
  if [ -n "$disko" ]; then
    say "$host declares a disko layout ($disko): install.sh deploys through terraform.sh — declare hosts/$host/terraform.json instead"
    exit 2
  fi
  # The recipe is the layout declaration. Where the file exists it is what install.sh acts on, and
  # its owns must agree with the one fact that says who may partition the drive: a recipe claiming a
  # drive this host does not own is refused before any write. A host that owns its drive must have
  # one — there is no other declaration of what a fresh gpt table should hold.
  recipe=""
  recipe_file="hosts/$host/terraform.json"
  if [ -f "$recipe_file" ]; then
    declared=$(jq -r '.owns' "$recipe_file")
    if [ "$declared" != "$owned" ]; then
      say "$host: $recipe_file says owns=$declared but flakeHost.ownsWholeDisk is $owned — one of them is wrong"
      exit 2
    fi
    recipe="$recipe_file"
  elif [ "$owned" = "true" ]; then
    say "$host owns its disk: $recipe_file must declare the layout terraform.sh reproduces"
    exit 2
  fi
  # Both kinds of drive are named the same way: the host's mounts name a partition, lsblk names the
  # drive holding it, and a drive nothing has formatted yet is the one real drive here (ADR-b77ec913151f).
  if [ -z "$esp_device" ]; then
    say "$host: no /boot mount is declared, so there is no ESP to adopt"
    exit 2
  fi
  target_disk
  if [ "$owned" = "true" ]; then
    say "$host owns $device outright: terraform.sh reproduces $recipe_file onto it"
  else
    say "$host shares $device: terraform.sh adopts the partitions it declares"
  fi
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
  if [ "$owned" = "true" ]; then
    say "$host: drive $device owned, layout from $recipe_file, mounts under $root"
  else
    say "$host: drive $device shared, partitions adopted, mounts under $root"
  fi
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
  # terraform.sh is the only thing that touches the drive, and it prompts for each destructive step
  # itself (ADR-b77ec913151f): a fresh gpt table on a drive this host owns, a mkfs of a blank
  # partition on a drive it shares. This stage adds no prompt of its own; --force is the only
  # non-interactive override, and --dry-run runs nothing. A second run adopts what the drive already
  # holds instead of rebuilding it.
  tf=()
  if [ "$dry" = 1 ]; then tf+=(--dry-run); fi
  if [ "$force" = 1 ]; then tf+=(--force); fi
  if [ -n "$recipe" ]; then
    run ./terraform.sh "${tf[@]}" --recipe "$recipe" --disk "$device" --mount "$root" ||
      say "terraform.sh reported a failure"
  else
    run ./terraform.sh "${tf[@]}" --disk "$device" --mount "$root" --root-fs "$root_fs" \
      --root-device "$root_device" --esp-device "$esp_device" ||
      say "terraform.sh reported a failure"
  fi
  # Nothing runs under --dry-run, so there is nothing to check afterwards. The stage's contract is
  # the mount, so a terraform.sh failure surfaces as the missing mount.
  if [ "$dry" = 1 ]; then return; fi
  src=$(store_mount) || {
    say "terraform left $root unmounted — the layout is not on the drive yet, deploy cannot run"
    exit 2
  }
  what="the partitions $host declares"
  [ "$owned" = "true" ] && what="the layout $recipe declares"
  say "terraform ok: $root mounted from $what ($src)"
}

deploy() {
  resolve
  store_mount >/dev/null || {
    say "deploy needs terraform first: nothing disk-backed is mounted at $root or $root/nix"
    exit 2
  }
  # The drive has to still match the recipe the layout was built from. --verify reads it and writes
  # nothing, so a drive that changed since terraform ran refuses the install rather than being
  # installed onto.
  if [ -n "$recipe" ]; then
    run ./terraform.sh --verify --recipe "$recipe" --disk "$device" || {
      say "deploy refused: $device no longer matches $recipe"
      exit 2
    }
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
