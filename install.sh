#!/usr/bin/env bash
# install.sh — staged installer for a host, on a drive this flake owns alone or shares.
#
#   prepare    read-only: host + drive checks, temporary zram, partition-table checksum
#   terraform  ./terraform.sh reproduces the host's layout onto the drive: a drive we own gets a
#            fresh gpt table from hosts/<host>/terraform.json; a drive we share adopts the
#            partitions the host declares. Either way the target store lands on the disk.
#   deploy     nixos-install --root <dir>: the closure builds into <dir>/nix/store and the boot
#            loader is written (nixos-install runs switch-to-configuration boot itself)
#   postdeploy  writes into the installed tree only: ssh keys for the host's users, and a password
#            for root and every wheel user. Nothing installs here.
#   reboot     only after deploy and postdeploy
#
# One prompt per stage, asked right before that stage writes: terraform asks only when the drive is
# about to change, deploy always (an install is not read-only), postdeploy per password because only
# a terminal can answer one. --force or
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
# evals and the install build go to a store under /run (tmpfs, 755).
scratch="${INSTALL_SCRATCH:-/run/flakeroot-scratch}"
# INSTALL_PASSWORDS (user:password lines), INSTALL_SYSTEM (a toplevel store path) and INSTALL_DRIVE
# (the drive to deploy onto) are the non-interactive path: passwords without a terminal, an install
# of a closure built on the machine that called the installer rather than one built inside it, and a
# target drive for a guest whose root is tmpfs and so names no drive of its own.
# Installer ISOs differ in what their nix.conf enables, and the flake commands here need both.
export NIX_CONFIG="experimental-features = nix-command flakes"

usage() {
  printf 'usage: install.sh [--dry-run] [--force] [--root <dir>] [--scratch <dir>] [--stage prepare|terraform|deploy|postdeploy|reboot|all[,<stage>...]] <host>\n'
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

# `--stage` takes a comma list, so one call runs the stages in the order given: `prepare,terraform`
# is the first two steps of `all`, and `all` is the whole sequence in its fixed order.
IFS=, read -ra wanted <<<"$stage"
stages=()
for s in "${wanted[@]}"; do
  case "$s" in
  prepare | terraform | deploy | postdeploy | reboot) stages+=("$s") ;;
  all) stages+=(prepare terraform deploy postdeploy reboot) ;;
  '')
    printf 'install.sh: --stage names stages, not blanks (prepare,terraform)\n' >&2
    exit 2
    ;;
  *)
    printf 'install.sh: unknown stage %s\n' "$s" >&2
    exit 2
    ;;
  esac
done
if [ "${#stages[@]}" = 0 ]; then
  printf 'install.sh: --stage names at least one stage\n' >&2
  exit 2
fi

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

# The precondition deploy needs: a store on the target disk, not in the ISO's RAM. Where the host
# declares /nix as a mount, terraform.sh mounts @nix there and the store lands in that subvolume.
# Where it declares no /nix mount, the store is a directory inside the root filesystem -- findmnt
# answers for a mountpoint, never for a directory inside one, so both placements are checked. A tmpfs
# source is refused: it would build the closure into RAM.
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
  # A tmpfs-rooted guest names no drive: no mount source, no formatted partition. The caller names
  # it, and resolve's whole-disk check is what still refuses a partition or a file.
  if [ -n "${INSTALL_DRIVE:-}" ]; then
    device="$INSTALL_DRIVE"
    return
  fi
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
  #
  # An ISO can also present as a plain disk: this VM's /dev/sda is a dos table with iso9660 across the
  # whole drive. A drive carrying a filesystem end to end is media, not somewhere to lay a partition.
  while read -r name type rm; do
    if [ "$type" != disk ] || [ "$rm" = 1 ] || [ "/dev/$name" = /dev/zram0 ]; then continue; fi
    if [ -n "$(blkid -o value -s TYPE "/dev/$name" 2>/dev/null || true)" ]; then continue; fi
    disks="${disks:+$disks }/dev/$name"
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
  # One eval, five facts: who may partition the drive, what the host's mounts name, and every path it
  # mounts them at. terraform.sh is the only installer this script runs (ADR-b77ec913151f), so there
  # is no other layout declaration to read back. Evaluating the config once is cheaper than three
  # narrowed evals of it, and the ISO's /nix/store is an overlay whose upper half is a tiny tmpfs, so
  # every eval and build below goes to its own store instead.
  facts=$(scoped nix eval --store "$scratch" --impure --raw "$(attr)" \
    --apply 'c: builtins.concatStringsSep "\n" [
      (builtins.toString c.flakeHost.ownsWholeDisk)
      (c.fileSystems."/".device or "")
      (c.fileSystems."/".fsType or "")
      (c.fileSystems."/boot".device or "")
      (builtins.concatStringsSep " " (builtins.attrNames c.fileSystems))
    ]') || exit 2
  owned=$(printf '%s\n' "$facts" | sed -n 1p)
  # `builtins.toString` of a bool is `1` for true and `""` for false, and the recipe's `owns` is
  # true/false. The eval above exits non-zero when the option is missing, so anything that is not 1 is
  # a shared drive.
  case "$owned" in
  1) owned=true ;;
  *) owned=false ;;
  esac
  root_device=$(printf '%s\n' "$facts" | sed -n 2p)
  root_fs=$(printf '%s\n' "$facts" | sed -n 3p)
  esp_device=$(printf '%s\n' "$facts" | sed -n 4p)
  # The paths the installed system mounts, space-separated. deploy compares them against what is live
  # under $root; the root and the ESP are not compared there, because those have their own gates.
  mount_paths=$(printf '%s\n' "$facts" | sed -n 5p)
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
  # One prompt for the whole stage, asked only when the drive is about to change. The verdict comes
  # from routines that write nothing: --verify reads the recipe against the drive, and with no recipe
  # the declared mounts being live already says the same thing. The answer is carried to terraform.sh
  # as --force (ADR-b77ec913151f: --force is the operator's answer to the destructive prompt), so the
  # stage never asks twice and a drive that already matches is never asked about at all.
  tf=()
  if [ "$dry" = 1 ]; then
    tf+=(--dry-run)
  else
    changed=0
    if [ -n "$recipe" ]; then
      ./terraform.sh --verify --recipe "$recipe" --disk "$device" >/dev/null 2>&1 || changed=1
    else
      store_mount >/dev/null || changed=1
    fi
    if [ "$changed" = 1 ]; then
      confirm "terraform will change $device: partitions and filesystems are laid out on it, so anything currently on them is gone"
    fi
    tf+=(--force)
  fi
  failed=0
  if [ -n "$recipe" ]; then
    run ./terraform.sh "${tf[@]}" --recipe "$recipe" --disk "$device" --mount "$root" || failed=1
  else
    run ./terraform.sh "${tf[@]}" --disk "$device" --mount "$root" --root-fs "$root_fs" \
      --root-device "$root_device" --esp-device "$esp_device" || failed=1
  fi
  # Nothing runs under --dry-run, so there is nothing to check afterwards. The stage's contract is
  # the mount, so a terraform.sh failure surfaces as the missing mount.
  if [ "$dry" = 1 ]; then return; fi
  src=$(store_mount) || {
    say "terraform left $root unmounted — the layout is not on the drive yet, deploy cannot run"
    exit 2
  }
  # A failure can still leave the root mounted: the drive holds a layout that is not the recipe's, so
  # the stage must not call that ok.
  [ "$failed" = 0 ] || {
    say "terraform.sh reported a failure — the layout on $device is not what $recipe declares"
    exit 2
  }
  # Recording the filesystem identities is the stage's last act, after the reproduction and both
  # verification checks came back clean, so a run that failed leaves the recipe untouched. A recipe
  # that already carries them names every filesystem already, so there is nothing to record. deploy
  # refuses until the host recipe carries them; committing the recorded file is the operator's act.
  if [ -n "$recipe" ] && ! grep -q '"uuid"' "$recipe_file"; then
    run ./terraform.sh --record --recipe "$recipe" --disk "$device" --mount "$root" || {
      say "terraform could not record the filesystem identities — deploy refuses until $recipe_file carries them"
      exit 2
    }
    say "recorded the filesystem identities into $recipe_file: commit it and run nix flake check"
  fi
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
  # A recipe that declares no UUID names every filesystem by label, and a label is unique only within
  # one drive — two partitions can answer to one name. The terraform stage records the identities of
  # the filesystems it made or adopted into the recipe itself, so a mount names one filesystem, and the
  # config the flake derives from that recipe mounts exactly the layout the drive was built from.
  # Asked before the prompt, so a recipe nobody recorded never reaches it.
  if [ -n "$recipe" ] && ! grep -q '"uuid": *"[^"]*"' "$recipe"; then
    say "deploy refused: $recipe declares no filesystem UUID — run the terraform stage, which records them into $recipe, then commit it and re-run nix flake check"
    exit 2
  fi
  # The drive has to still match the recipe the layout was built from. --verify reads it and writes
  # nothing, so a drive that changed since terraform ran refuses the install rather than being
  # installed onto.
  if [ -n "$recipe" ]; then
    run ./terraform.sh --verify --recipe "$recipe" --disk "$device" || {
      say "deploy refused: $device no longer matches $recipe"
      exit 2
    }
  fi
  # The staging mount set has to be the mount set this host reads at boot (ADR-97fb20bfd175): every subvolume the config mounts must be live under $root before
  # nixos-install runs, or deploy writes into one filesystem and boot reads another. An empty @nix
  # mounted over /nix is not cosmetic -- /nix/store ends up empty, stage 2's init is not in it, and
  # the host lands in emergency.target. Asked before the prompt, so a tree that is not there never
  # reaches an answer. shortcut: / and /boot are not checked here -- store_mount above answers for the
  # root and terraform.sh mounts and verifies the ESP; upgrading means checking every declared path.
  missing=""
  for path in $mount_paths; do
    case "$path" in
    / | /boot) continue ;;
    esac
    findmnt -n -o SOURCE "$root$path" >/dev/null 2>&1 || missing="${missing:+$missing }$path"
  done
  if [ -n "$missing" ]; then
    say "deploy refused: $missing is not mounted under $root — the tree terraform.sh laid down is not the tree $host mounts"
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
  # INSTALL_SYSTEM installs a closure built somewhere else. The VM tier builds on the host and
  # hands the store path over, because a flake evaluation inside a 1GB guest is exactly the thing
  # that overflows a RAM-constrained machine. Without it, deploy builds from the flake as always.
  if [ -n "${INSTALL_SYSTEM:-}" ]; then
    run scoped nixos-install --system "$INSTALL_SYSTEM" --root "$root" --no-root-passwd
  else
    run scoped nixos-install --flake ".#$host" --root "$root" --no-root-passwd
  fi
  say "deploy ok: $host installed on $root, boot loader written — run --stage postdeploy for ssh keys and passwords"
}

# The way into the freshly installed system, and nothing else: --no-root-passwd leaves every account
# with no password, and the installer knows only the ISO operator's keys, not the keys of the users
# this host declares. This stage writes inside $root only — files under $root/home and passwd entries
# of the installed system — never the drive.
postdeploy() {
  resolve
  store_mount >/dev/null || {
    say "postdeploy needs the installed root mounted: run terraform first"
    exit 2
  }
  # The keys belong to the users this host declares, not to whoever ran the ISO, and under sudo
  # $HOME is root's, so they come from whoever invoked the installer.
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
    say "postdeploy found no wheel user in $host's config — the design needs at least one admin"
    exit 2
  fi
  # The freshly installed system has no /run/current-system yet, so the installer environment's own
  # nixos-enter is what gives a command inside it a working PATH.
  how="nixos-enter --root $root --"
  # Passwords come from the environment when there is no terminal to answer a prompt — the VM tier,
  # and any scripted run. Lines are user:password; only root or a wheel admin this host declares may
  # be named, and the value travels on stdin only, because argv lands in the call log and stdout
  # lands in the serial log the caller keeps.
  if [ -n "${INSTALL_PASSWORDS:-}" ]; then
    # Validate the whole batch before anything is written: a batch naming someone this host does not
    # declare must leave the tree untouched, not leave it half-set.
    pairs=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      user=${line%%:*}
      known=0
      for a in root $admins; do
        [ "$user" = "$a" ] && known=1 && break
      done
      if [ "$known" != 1 ]; then
        say "postdeploy refused: $user has a password in INSTALL_PASSWORDS but is not an admin of $host"
        exit 2
      fi
      pairs+=("$line")
    done <<<"$INSTALL_PASSWORDS"
    for line in "${pairs[@]}"; do
      printf '%s\n' "$line" | run nixos-enter --root "$root" -- chpasswd
      say "password set for ${line%%:*}"
    done
  else
    # Only a real terminal can answer a password prompt; --force must never block on one.
    for a in root $admins; do
      if [ -t 0 ] && confirm "set a password for $a now (prompts twice, no current password needed)"; then
        run nixos-enter --root "$root" -- passwd "$a"
        say "password set for $a"
      else
        say "no password set for $a — run \`$how passwd $a\` before reboot, nothing sets a password"
      fi
    done
  fi
  say "postdeploy ok: ssh keys installed, passwords set where a terminal could answer — reboot once root and an admin have passwords"
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

for s in "${stages[@]}"; do
  case "$s" in
  prepare) prepare ;;
  terraform) terraform ;;
  deploy) deploy ;;
  postdeploy) postdeploy ;;
  reboot) reboot_stage ;;
  esac
done
