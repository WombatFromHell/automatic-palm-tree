#!/usr/bin/env bash
# terraform.sh — disk management for a host whose drive this flake does NOT own (ADR-b77ec913151f).
#
# disko rewrites the GUID, name and type code of any partition index it names, so it may only run on
# a drive we own alone. A shared drive gets this instead: read the table, adopt the ESP and the root
# partition the host declares, and format a partition only where blkid reports no signature.
#
# It never writes a partition entry: no wipefs, no sfdisk/sgdisk write, no resize. The first megabyte
# of the drive (the partition table) is checksummed before and after, and a run that moved it fails.
# Every destructive step goes through lib/confirm.sh: --force or INSTALL_FORCE=1 is the testing
# override, --dry-run runs nothing, and a run with no terminal is refused.
#
# --emit prints the recipe a drive describes (ADR-2e63b3079610): JSON on stdout, guidance on stderr,
# no write of any kind.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/confirm.sh
. lib/confirm.sh

disk=""
mount="/mnt"
root_fs="ext4"
# null means the root's options were never declared, which is what lets mount_opts fall back to the
# filesystem's defaults; "" is a declared choice and means the kernel's defaults.
root_opts=null
root_device=""
esp_device=""
recipe=""
emit=""
verify=""
owns=false
dry=0
force="${INSTALL_FORCE:-0}"

usage() {
  printf 'usage: terraform.sh [--dry-run] [--force] --recipe <file> [--disk <drive>] [--mount <dir>]\n'
  printf '       terraform.sh [--dry-run] [--force] --disk <drive> --mount <dir> --root-fs <type> --root-device <path> --esp-device <path>\n'
  printf '       terraform.sh --emit [--disk <drive>]   read-only: prints the recipe this drive describes\n'
  printf '       terraform.sh --recipe <file> --verify   read-only: does the drive match the recipe?\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
  --emit) emit=1 ;;
  --dry-run) dry=1 ;;
  --force) force=1 ;;
  --verify) verify=1 ;;
  --recipe)
    recipe="$2"
    shift
    ;;
  --disk)
    disk="$2"
    shift
    ;;
  --mount)
    mount="$2"
    shift
    ;;
  --root-fs)
    root_fs="$2"
    shift
    ;;
  --root-device)
    root_device="$2"
    shift
    ;;
  --esp-device)
    esp_device="$2"
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  -*)
    printf 'terraform.sh: unknown flag %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  *)
    printf 'terraform.sh: unexpected argument %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

refuse() {
  printf 'terraform.sh: %s\n' "$*" >&2
  exit 2
}

# Checked once, up front: every partition-table read below goes through jq, and a table that holds
# no partitions must be reported as an empty table, never as a missing tool.
command -v jq >/dev/null || refuse "jq is required to read the partition table"

# Field separator for the rows jq hands to the read loops below. A tab would not do: read collapses
# consecutive whitespace separators, so a partition with no filesystem label or no GPT name would
# shift every field after it. Unit separator is not whitespace and appears in no path or label.
sep=$'\u001f'

# A partition with a signature is somebody else's filesystem or somebody else's data; a partition
# without one is space we may fill. blkid exits non-zero when it finds nothing, which is the answer.
signature() { blkid -o value -s TYPE "$1" 2>/dev/null || true; }

# The label a filesystem carries, which is what a recipe entry is checked against.
label_of() { blkid -o value -s LABEL "$1" 2>/dev/null || true; }

# A partition with no type declared still needs a GPT type: a vfat partition is an ESP, anything
# else is a Linux filesystem partition. The ESP GUID, not the FAT32 GUID — firmware scans partitions
# by the ESP GUID (UEFI 2.7 §12.3), which is what a real ESP carries (C12A7328… on the VM's
# nvme0n1p1); a FAT32-typed partition is a data volume that firmware walks past.
default_type() {
  case "$1" in
  vfat) printf 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' ;;
  *) printf '0FC63DAF-8483-4772-8E79-3D69D8457574\n' ;;
  esac
}

# mount_opts <fs> [declared] — the options a mount of <fs> is made with, taken from what
# hosts/methyl-nixos/nixos.nix declares for a btrfs UEFI host: every subvolume of the btrfs root is
# mounted noatime,compress=zstd (atime writes cost I/O on a store that is read constantly, and zstd
# is what that host already compresses with), an xfs root is mounted noatime with a 256k log buffer
# and no quota (the log buffer is where xfs spends its journal writes, and quotas are not used here),
# and a vfat ESP is mounted with the 0077 masks so the boot loader files are not world-readable. A
# recipe entry's own options win; ext4 gets noatime only, and takes the kernel's for everything else.
# An entry that declares "options": "" wins too — it means the kernel's defaults, not this fallback.
mount_opts() {
  local declared=${2-null}
  if [ "$declared" != null ]; then
    printf '%s\n' "$declared"
    return
  fi
  case "$1" in
  ext4) printf 'noatime\n' ;;
  btrfs) printf 'noatime,compress=zstd\n' ;;
  xfs) printf 'noatime,logbsize=256k,noquota\n' ;;
  vfat) printf 'fmask=0077,dmask=0077\n' ;;
  esac
}

# mount_extra <node> <dir> <fs> [declared options] — mount a partition under the mount root. Mounting
# is not destructive, so it is never prompted, and a mount that is already there is adopted. deploy
# needs every mount the host declares present: nixos-install writes the boot loader into
# efiSysMountPoint, and systemd-boot refuses a /boot that is not a mount.
mount_extra() {
  local node="$1" dir="$2" fs="$3" opts
  opts=$(mount_opts "$3" "${4-null}")
  # The mount point has to exist before anything can be mounted on it, and an empty directory on a
  # filesystem being installed onto is not a destructive step.
  run mkdir -p "$dir"
  if findmnt -n -o SOURCE "$dir" >/dev/null 2>&1; then
    say "$dir already mounted — adopted, not rebuilt"
    return
  fi
  if [ -n "$opts" ]; then
    run mount -o "$opts" "$node" "$dir"
  else
    run mount "$node" "$dir"
  fi
}

# recipe_opts <name> — the options string a recipe entry declares. "null" is printed when the entry
# declares none, which is what mount_opts reads as "use the per-filesystem defaults"; an entry that
# declares "options": "" prints the empty string, which means the kernel's defaults.
recipe_opts() {
  [ -n "$recipe" ] || return 0
  jq -r --arg n "$1" '.partitions[] | select(.name == $n) | (if .options == null then "null" else .options end)' "$recipe" 2>/dev/null || true
}

# A device path that names a partition by the UUID a generated hardware-configuration.nix recorded.
# Formatting a partition that a UUID path points at is the failure this refuses: a mkfs that
# cannot finish never leaves half a disk formatted: mkfs would create a UUID the generated
# hardware-configuration.nix never learned.
check_uuid() {
  local node="$1" device="$2" sig="$3"
  [ -n "$sig" ] && return 0
  case "$device" in
  /dev/disk/by-uuid/*)
    refuse "$device is named by UUID, and formatting $node would give it a UUID the host's hardware-configuration.nix cannot know — generate the config on the installed host, or declare the mount by label"
    ;;
  esac
}

# Format a blank partition, and only a blank one.
format_blank() {
  local node="$1" fs="$2" device="$3" sig="$4" fresh="${5:-0}"
  # A partition already holding the filesystem the recipe declares is adopted, not formatted.
  [ -n "$sig" ] && [ "$sig" = "$fs" ] && return 0
  # A partition holding some other filesystem is formatted only where this run owns it: a partition
  # freshly created under a new table (the old table's superblocks stay in those bytes), or an owned
  # drive whose partition carries the wrong filesystem. On a shared drive it is somebody else's data,
  # so it is left alone and verification refuses the drive.
  [ -n "$sig" ] && [ "$fresh" = 0 ] && return 0

  local label=""
  case "$device" in /dev/disk/by-label/*) label="${device##*/}" ;; esac

  confirm "format $node as $fs: every byte currently in it is gone" || return 2

  local args=()
  case "$fs" in
  vfat)
    # mkfs.fat has no force flag: it writes over whatever is there.
    args=(-F 32)
    [ -n "$label" ] && args+=(-n "$label")
    ;;
  ext4)
    args=(-q)
    [ -n "$label" ] && args+=(-L "$label")
    # -F (not -f) is what lets mkfs.ext4 write over a partition that still carries a superblock.
    [ "$fresh" = 1 ] && args+=(-F)
    ;;
  xfs)
    # -f is what lets a fixture format a slice that is a regular file, and what lets a real one write
    # over a partition whose old superblock is still in place.
    if [ -f "$node" ] || [ "$fresh" = 1 ]; then args+=(-f); fi
    [ -n "$label" ] && args+=(-L "$label")
    ;;
  btrfs)
    # mkfs.btrfs refuses a partition that still carries another filesystem's superblock.
    [ "$fresh" = 1 ] && args+=(-f)
    [ -n "$label" ] && args+=(-L "$label")
    ;;
  *) refuse "terraform.sh does not know how to format $fs" ;;
  esac
  run "mkfs.$fs" "${args[@]}" "$node"
}

# Which of these partitions the host claims as its root: one already holding the filesystem the host
# declared, or a blank one whose GPT type says a Linux filesystem. Signatures it passed over are
# collected in $seen, because "no partition holds ext4" is a different answer from "it holds ntfs".
# It sets $root_part rather than printing, so $seen and $root_part survive the call.
root_part=""
seen=""
find_root() {
  local parts="$1" fs="$2" node type sig
  while read -r node type; do
    [ -n "$node" ] || continue
    sig=$(signature "$node")
    if [ -n "$sig" ]; then
      if [ "$sig" = "$fs" ]; then
        root_part="$node"
        return 0
      fi
      seen="$seen $sig"
      continue
    fi
    case "${type^^}" in
    0FC63DAF-8483-4772-8E79-3D69D8457574 | EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
      root_part="$node"
      return 0
      ;;
    esac
  done <<<"$parts"
  return 1
}

# Recipe sizes are what --emit prints (exact whole units) or what a human writes: bytes, or K/M/G.
# `rest` is not a number, so it is returned as the word and the caller decides what it means.
size_bytes() {
  local s="$1"
  case "$s" in
  rest) printf 'rest\n' ;;
  *K) printf '%s\n' $((${s%K} * 1024)) ;;
  *M) printf '%s\n' $((${s%M} * 1024 * 1024)) ;;
  *G) printf '%s\n' $((${s%G} * 1024 * 1024 * 1024)) ;;
  '' | *[!0-9]*) refuse "recipe size '$s' is not bytes, K, M, G or rest" ;;
  *) printf '%s\n' "$s" ;;
  esac
}

# A recipe may give a partition type as a GUID or as the 4-character typecode sfdisk also accepts.
# sfdisk --json reports GUIDs, so both are compared as GUIDs.
type_guid() {
  case "${1^^}" in
  83) printf '0FC63DAF-8483-4772-8E79-3D69D8457574\n' ;;
  EF00) printf 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' ;;
  *) printf '%s\n' "${1^^}" ;;
  esac
}

# sect_of <node> — the partition's length in sectors, read off the table.
sect_of() {
  printf '%s\n' "$table" | jq -r --arg node "$1" '.partitiontable.partitions[] | select(.node == $node) | .size'
}

# holds_size <node> <declared> — whether that partition is at least as large as the entry asks for.
# An entry with no size, or `rest`, asks for nothing specific: what it adopts is whatever it is.
holds_size() {
  local sect
  [ -z "$2" ] && return 0
  local want
  want=$(size_bytes "$2")
  [ "$want" = rest ] && return 0
  sect=$(sect_of "$1")
  [ -n "$sect" ] && [ "$sect" != null ] && [ $((sect * 512)) -ge "$want" ]
}

# The partition the host's own mount point names, when that name resolves on this machine and is one
# of the partitions on this disk. Choosing by signature alone could pick a filesystem of the same
# type that another install owns.
declared_node() {
  local node
  node=$(realpath -e "$1" 2>/dev/null || true)
  if [ -n "$node" ] && printf '%s\n' "$node" | grep -qxF "$nodes"; then
    printf '%s\n' "$node"
  fi
}

# gpt_name <node> — the name the GPT gives a partition, read off the table.
gpt_name() {
  printf '%s\n' "$table" | jq -r --arg node "$1" '.partitiontable.partitions[] | select(.node == $node) | .name // ""'
}

# What a drive offers as a boot partition that the recipe did not accept: FAT under some other
# label, or a blank partition whose GPT type says boot. Naming them turns "nothing here is /boot"
# into "declare the label this ESP actually carries".
esp_offers() {
  local cand type sig out=""
  while read -r cand type; do
    [ -n "$cand" ] || continue
    sig=$(signature "$cand")
    if [ -n "$sig" ]; then
      [ "$sig" = vfat ] || continue
      out="$out $cand (vfat, label $(label_of "$cand"))"
      continue
    fi
    case "${type^^}" in
    C12A7328-F81F-11D2-BA4B-00A0C93EC93B | C12A7EA9-344C-4175-A575-202976385741)
      out="$out $cand (blank, GPT type ${type^^})"
      ;;
    esac
  done <<<"$parts"
  [ -n "$out" ] || out=" no FAT partition and no partition the GPT type says is boot"
  printf '%s\n' "$out"
}

# resolve_entries — where each recipe entry lives on the drive today, in the order the recipe allows:
# the device its own label names, a partition holding the entry's filesystem under the entry's label,
# a blank partition whose GPT type or GPT name says the entry. A partition holding the right
# filesystem under somebody else's label is named, never taken, and a partition an earlier entry
# claimed is never claimed twice: two entries wanting one partition is a recipe contradiction.
# Fills resolved[] by entry index.
# Discovery runs the same resolution; it never refuses a candidate, so the run's own loud refusal is
# skipped while discovery is asking (drive_matches sets and clears this).
discovering=0

resolve_entries() {
  local line name label fs size type mnt node cand t sig taken=""
  resolved=()
  taken=" "
  for line in "${entry_lines[@]}"; do
    IFS="$sep" read -r name label fs size type mnt <<<"$line"
    node=""
    case "$name" in
    "$esp_name") node=$(declared_node "$esp_device") ;;
    "$root_name") node=$(declared_node "$root_device") ;;
    esac
    while read -r cand t; do
      [ -n "$cand" ] || continue
      if [ -n "$node" ]; then continue; fi
      case "$taken" in *" $cand "*) continue ;; esac
      sig=$(signature "$cand")
      if [ "$sig" = "$fs" ]; then
        if [ -z "$label" ] || [ "$(label_of "$cand")" = "$label" ]; then
          if holds_size "$cand" "$size"; then
            node="$cand"
          elif [ "$discovering" = 0 ]; then
            # A filesystem under the recipe's own label that is smaller than the recipe asks for is
            # somebody's install, and a second partition with the same label would be two devices
            # answering to one name. resize is never attempted, so this is answered here, before any
            # write, rather than by formatting something else.
            refuse "recipe entry $name: $cand holds $fs labelled $label and $(human_size "$(($(sect_of "$cand") * 512))"), which is less than the $size the recipe asks for: resize is never attempted"
          fi
        fi
        continue
      fi
      if [ -z "$sig" ] && holds_size "$cand" "$size" &&
        { [ "${t^^}" = "$(type_guid "${type:-$(default_type "$fs")}")" ] || [ "$(gpt_name "$cand")" = "$name" ]; }; then
        node="$cand"
      fi
    done <<<"$parts"
    if [ -n "$node" ]; then
      case "$taken" in *" $node "*) refuse "$name and an earlier entry both claim $node: one partition is not two partitions" ;; esac
      taken="$taken$node "
    fi
    resolved+=("$node")
  done
}

# drive_matches <path> — whether this drive holds a partition any entry of the recipe resolves to.
# Discovery asks the run's own question instead of a fingerprint of its own, so a drive a recipe
# would append into is found as readily as one it would adopt.
drive_matches() {
  local path="$1" n
  table=$(sfdisk --json "$path" 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$table" | jq -r '(.partitiontable.partitions // [])[] | "\(.node) \(.type)"' 2>/dev/null) || return 1
  nodes=$(printf '%s\n' "$parts" | cut -d ' ' -f1)
  # While discovery is asking, "this drive cannot hold the recipe" is an answer about one drive, not
  # a refusal of the whole run: the drive that gets chosen is the one the run then refuses loudly.
  discovering=1
  resolve_entries
  discovering=0
  for n in "${!resolved[@]}"; do
    if [ -n "${resolved[n]}" ]; then return 0; fi
  done
  return 1
}

# candidate_disks — the drives this script may consider: real disks, not removable media, not zram.
# A lsblk name is a bare kernel name on a real machine and a full path in the disk-fixture tier, and
# both are plain paths to every tool below, so one mapping serves both.
candidate_disks() {
  lsblk -J -b -o NAME,TYPE,RM 2>/dev/null |
    jq -r '.blockdevices[] | select(.type == "disk" and .rm == false and .name != "zram0") | .name'
}

disk_path() {
  if [ -e "$1" ]; then printf '%s\n' "$1"; else printf '/dev/%s\n' "$1"; fi
}

# The drive the recipe lives on, found by the recipe's own fingerprints rather than by a kernel name
# that changes between machines. Removable media and zram are never a drive; a drive whose table
# cannot be read is not ours. Zero or several matches refuse rather than guess.
discover_disk() {
  local candidates="" name cand
  while read -r name; do
    [ -n "$name" ] || continue
    cand=$(disk_path "$name")
    drive_matches "$cand" && candidates="$candidates $cand"
  done < <(candidate_disks)
  case "$candidates" in
  '')
    refuse "no drive matches the recipe: no partition here holds a filesystem the recipe declares and none carries the type one of its entries names"
    ;;
  *)
    [ "$(printf '%s\n' "$candidates" | wc -w)" = 1 ] ||
      refuse "two drives match the recipe ($candidates): name one with \"disk\" in the recipe or --disk"
    printf '%s\n' "${candidates# }"
    ;;
  esac
}

# --emit: the recipe the drive describes, printed and written by nobody but the operator. Only a
# partition whose signature is a filesystem format_blank can make is emitted — a blank partition
# carries no intent, so guessing one would print a recipe that formats something nobody asked for
# (ADR-2e63b3079610). stdout is JSON alone so `--emit > hosts/<host>/terraform.json` is the workflow;
# everything a human has to change is stderr.

# Exact size in the largest whole unit, so a recipe never disagrees with the partition it describes:
# a size rounded down would fail the free-space precheck the moment the recipe is resized.
human_size() {
  local bytes="$1" unit mult
  for unit in G M K; do
    case "$unit" in
    G) mult=$((1024 * 1024 * 1024)) ;;
    M) mult=$((1024 * 1024)) ;;
    K) mult=1024 ;;
    esac
    if [ $((bytes % mult)) -eq 0 ]; then
      printf '%s%s\n' "$((bytes / mult))" "$unit"
      return
    fi
  done
  printf '%d\n' "$bytes"
}

if [ -n "$emit" ]; then
  [ -z "$recipe" ] || refuse "--emit writes a recipe from the drive; --recipe reads one: pick one"
  if [ -z "$disk" ]; then
    found=$(candidate_disks)
    [ -n "$found" ] || refuse "no disk found: name the drive with --disk"
    [ "$(printf '%s\n' "$found" | wc -w)" = 1 ] ||
      refuse "several disks found ($(printf '%s\n' "$found" | tr '\n' ' ')): name one with --disk"
    disk=$(disk_path "$found")
  fi
  command -v sfdisk >/dev/null || refuse "sfdisk is required to read the partition table"
  table=$(sfdisk --json "$disk" 2>/dev/null) || refuse "no partition table on $disk: nothing to emit"
  rows=$(printf '%s\n' "$table" | jq -r '(.partitiontable.partitions // []) | to_entries[] | "\(.key+1)\u001f\(.value.node)\u001f\(.value.size)\u001f\(.value.name // "")"' 2>/dev/null) ||
    refuse "cannot read the partition table on $disk"
  [ -n "$rows" ] || refuse "no partitions on $disk: nothing to emit"

  # The largest non-vfat filesystem is the root candidate; its name is remembered so its mount is
  # set when the JSON is written, rather than patched into the rows afterwards.
  kept=()
  best_name=""
  best_bytes=0
  skipped=""
  while IFS="$sep" read -r idx node size pname; do
    [ -n "$node" ] || continue
    fs=$(signature "$node")
    # A left-out partition is named the way a human would recognise it: the GPT partition name, with
    # the index as the fallback when the table has no name to read.
    known="${pname:-partition $idx}"
    if [ -z "$fs" ]; then
      skipped="$skipped $known (no filesystem)"
      continue
    fi
    case "$fs" in
    ext4 | vfat | btrfs) ;;
    *)
      skipped="$skipped $known ($fs)"
      continue
      ;;
    esac
    label=$(blkid -o value -s LABEL "$node" 2>/dev/null || true)
    name=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
    # An unlabeled partition still needs a handle in the recipe: a vfat partition is an ESP whatever
    # it came with, and name is only the handle the plan and subvolumes print, not a device name.
    if [ -z "$name" ]; then
      if [ "$fs" = vfat ]; then name="esp"; else name="p$idx"; fi
    fi
    mount=""
    bytes=$((size * 512))
    if [ "$fs" = vfat ]; then
      mount="/boot"
    elif [ "$bytes" -gt "$best_bytes" ]; then
      best_name="$name"
      best_bytes="$bytes"
    fi
    kept+=("$name$sep$label$sep$fs$sep$(human_size "$bytes")$sep$mount$sep$(mount_opts "$fs")")
  done <<<"$rows"

  if [ "${#kept[@]}" = 0 ]; then
    refuse "nothing on $disk has a filesystem terraform.sh can reproduce (${skipped# }): a recipe that identifies nothing is not a recipe"
  fi
  # $root is empty when nothing was a root candidate, and a row never has an empty name, so the
  # guess only ever lands on the largest filesystem.
  jq -n --arg rows "$(printf '%s\n' "${kept[@]}")" --arg sep "$sep" --arg root "$best_name" '{
    owns: false,
    partitions: ($rows / "\n" | map(select(. != "")) | map(
      . as $r | ($r / $sep) |
      {name: .[0], label: .[1], fs: .[2], size: .[3], mount: (if .[0] == $root and .[4] == "" then "/" else .[4] end), options: .[5]}
      | with_entries(select(.value != ""))))
  }'

  printf 'terraform.sh --emit: read %s — %d partition(s) terraform.sh can reproduce\n' "$disk" "${#kept[@]}" >&2
  if [ -n "$skipped" ]; then
    printf 'terraform.sh --emit: left out%s — a partition left out is blank or holds a filesystem terraform.sh does not format, so declare the one you want\n' "$skipped" >&2
  fi
  if [ -z "$best_name" ]; then
    printf 'terraform.sh --emit: no partition mounts / yet — declare the Linux partition you intend to create\n' >&2
  fi
  printf 'terraform.sh --emit: mounts are guesses (largest filesystem as /, vfat as /boot); sizes and filesystems came off the drive\n' >&2
  printf 'terraform.sh --emit: options are the ones hosts/<host>/nixos.nix mounts that filesystem with\n' >&2
  printf 'terraform.sh --emit: next: terraform.sh --recipe <file> --mount <dir> --verify\n' >&2
  exit 0
fi

# The recipe (hosts/<host>/terraform.json) is the layout a host declares. It replaces the flags that
# name a filesystem and a device path: the labels it declares become the device names, and the drive
# itself is found by discovery rather than a kernel name that moves between machines.
esp_name="esp"
root_name="root"
claimed=""
if [ -n "$recipe" ]; then
  [ -f "$recipe" ] || refuse "recipe $recipe does not exist"
  owns=$(jq -r '.owns // false' "$recipe")
  case "$owns" in
  true | false) ;;
  *) refuse "recipe owns must be true or false, not $owns" ;;
  esac
  # Mount options are declared per partition as a comma list, the same list disko's mountOptions
  # holds. A space would reach mount as two separate arguments, so it is refused here rather than
  # passed on to fail later.
  declared_opts=$(jq -r '[.partitions[] | .options // empty] | join(",")' "$recipe" 2>/dev/null || true)
  case "$declared_opts" in
  *" "*) refuse "recipe options must be a comma-separated list, not \"$declared_opts\"" ;;
  esac
  # Options that only one filesystem takes are refused on a partition that is not that filesystem:
  # mount would hand them to a filesystem with no such parameter and fail on an unknown option. The
  # fallback in mount_opts is already scoped by filesystem; this is the declared case. quota is not
  # in the list because ext4 takes it too.
  mismatched=$(jq -r '[.partitions[] | select(.fs != "btrfs") | select((.options // "") | test("compress=|subvol=|datacow|space_cache|ssspread|flushoncommit")) | "\(.name): \(.options)"] | join("; ")' "$recipe" 2>/dev/null || true)
  [ -z "$mismatched" ] || refuse "the recipe mounts a non-btrfs partition with btrfs options — $mismatched"
  mismatched=$(jq -r '[.partitions[] | select(.fs != "xfs") | select((.options // "") | test("logbsize=|inode64")) | "\(.name): \(.options)"] | join("; ")' "$recipe" 2>/dev/null || true)
  [ -z "$mismatched" ] || refuse "the recipe mounts a non-xfs partition with xfs options — $mismatched"
  root_opts=$(jq -r '.partitions[] | select(.mount == "/") | (.options // "null")' "$recipe" 2>/dev/null || true)
  entries=$(jq -r '.partitions[] | "\(.name)\u001f\(.label // "")\u001f\(.fs)\u001f\(.size // "")\u001f\(.type // "")\u001f\(.mount // "")"' "$recipe" 2>/dev/null) ||
    refuse "cannot read recipe $recipe"
  [ -n "$entries" ] || refuse "recipe $recipe declares no partitions"
  roots=0
  entry_lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then entry_lines+=("$line"); fi
  done <<<"$entries"
  while IFS="$sep" read -r name label fs size type mnt; do
    case "$fs" in
    ext4 | vfat | btrfs | xfs) ;;
    *) refuse "recipe declares $fs, which terraform.sh does not know how to format" ;;
    esac
    if [ "$mnt" = "/" ]; then
      roots=$((roots + 1))
      root_fs="$fs"
      root_name="${name:-root}"
      [ -n "$label" ] && root_device="/dev/disk/by-label/$label"
    elif [ "$fs" = vfat ]; then
      esp_name="${name:-esp}"
      [ -n "$label" ] && esp_device="/dev/disk/by-label/$label"
    fi
    claimed="$claimed$sep$fs$sep"
  done <<<"$entries"
  [ "$roots" = 1 ] || refuse "recipe must declare exactly one partition mounting / (found $roots)"
  # The root must be labelled because mkfs is what creates that label. The ESP need not be: a foreign
  # ESP usually has no label at all, and the run finds it by its vfat signature or GPT type, which
  # ADR-b77ec913151f already allows.
  [ -n "$root_device" ] || refuse "recipe must label the partition mounting /"
  [ -z "$disk" ] && disk=$(jq -r '.disk // ""' "$recipe" 2>/dev/null || true)
  if [ "$owns" = true ]; then
    # A wipe cannot be guessed. Nothing on a drive that is about to be erased identifies it, so the
    # drive has to be named by the recipe or by --disk.
    [ -n "$disk" ] || refuse 'owns=true wipes the whole drive: name it with --disk or a "disk" field'
  elif [ -z "$disk" ]; then
    disk=$(discover_disk)
  fi
fi

# The ESP need not be named: a foreign ESP often has no label at all, and the ESP is found by its
# vfat signature or GPT type below (ADR-b77ec913151f). The root must be named, because a blank root
# is formatted and the name is what identifies it afterwards. In owned mode there is no root to find
# yet: the run creates it.
if [ -z "$disk" ] || { [ "$owns" = false ] && [ -z "$root_device" ]; }; then
  usage >&2
  exit 2
fi
# Only the first megabyte: a mkfs writes at the partition's own offset, and a partition that starts
# at sector 2048 begins exactly there, so widening the window would fail a run that touched nothing.
table_checksum() { dd if="$disk" bs=1M count=1 status=none | md5sum | cut -d' ' -f1; }

# 1MiB is the alignment every partition is laid out to, and the last 1MiB of a drive is the backup
# partition table, so it is never usable space.
align=2048
command -v sfdisk >/dev/null || refuse "sfdisk is required to read the partition table"
table=$(sfdisk --json "$disk" 2>/dev/null || true)
parts=""
if [ -n "$table" ]; then
  parts=$(printf '%s\n' "$table" | jq -r '(.partitiontable.partitions // [])[] | "\(.node) \(.type)"' 2>/dev/null) ||
    refuse "cannot read the partition table on $disk"
fi
if [ "$owns" = false ]; then
  [ -n "$table" ] ||
    refuse "no partition table on $disk: terraform.sh never partitions a drive it does not own — create the ESP and the root partition first"
  [ -n "$parts" ] || refuse "no partitions on $disk: terraform.sh never partitions a drive it does not own"
fi
nodes=$(printf '%s\n' "$parts" | cut -d' ' -f1)
# The drive's own length is what the layout and the gap maths run on, so a drive whose size cannot be
# read is refused rather than treated as having infinite room. Only a recipe needs it: the flags mode
# adopts partitions that already exist and never sizes anything.
if [ -n "$recipe" ]; then
  disk_bytes=$(lsblk -J -b -o SIZE -- "$disk" 2>/dev/null | jq -r '.blockdevices[0].size // 0')
  [ "${disk_bytes:-0}" -gt 0 ] || refuse "cannot read the size of $disk: free-space maths needs it"
fi

# Owned mode claims the whole drive, so everything already on it has to be something the recipe
# reproduces. Raw filesystem bytes with no table are somebody's data; a DOS table is somebody else's
# layout; a filesystem no entry claims would be erased. Without --force every one of those refuses
# before any write. --force is the operator's answer to the destructive prompt, so a drive that already
# holds a partition table is rewritten over: what is being wiped is named first. A filesystem covering
# the whole drive is not a layout the recipe replaces, so that one stays refused either way.
if [ "$owns" = true ]; then
  if [ -n "$table" ]; then
    table_label=$(printf '%s\n' "$table" | jq -r '.partitiontable.label // "gpt"')
    if [ "$table_label" != gpt ]; then
      [ "$force" = 1 ] ||
        refuse "the partition table on $disk is $table_label, not gpt: owns=true rewrites the table, and a DOS table is somebody else's layout"
      say "$disk holds a $table_label table: --force replaces it with the recipe's gpt layout"
    fi
  else
    raw=$(blkid -o value -s TYPE "$disk" 2>/dev/null || true)
    [ -z "$raw" ] || refuse "$disk holds $raw across the whole drive: owns=true would wipe a filesystem no recipe entry claims"
  fi
  while read -r node _type; do
    [ -n "$node" ] || continue
    sig=$(signature "$node")
    [ -n "$sig" ] || continue
    case "$claimed" in
    *"$sep$sig$sep"*) ;;
    *)
      [ "$force" = 1 ] ||
        refuse "$node holds $sig, which no entry of the recipe claims: owns=true claims the whole drive"
      say "$node holds $sig: --force wipes it and lays the recipe's layout over it"
      ;;
    esac
  done <<<"$parts"
fi

# verify_recipe — re-read the drive against the recipe, read-only. An entry is satisfied when a
# partition holds its filesystem and its label and is at least as large as the recipe asked for; a
# rest entry has to reach the end of usable space, because resizing is never attempted. owns=true
# additionally requires the table to be exactly the recipe's entries, so an extra partition is a
# drive that does not match the recipe.
verify_recipe() {
  [ -n "$recipe" ] || refuse "--verify reads a recipe: --recipe is required"
  local i=0 name label fs size type mnt node sig got want sect end declared count held
  declared=$(printf '%s\n' "$entries" | grep -c '.' || true)
  count=$(printf '%s\n' "$parts" | grep -c '.' || true)
  # Partitions past the recipe are somebody else's layout, whether we are planning or verifying.
  # Fewer than the recipe is only a mismatch once the table has been written: a fresh drive holds
  # none, which is the case owns=true exists to build.
  if [ "$owns" = true ] && [ "$count" -gt "$declared" ]; then
    refuse "the table on $disk holds $count partitions and the recipe declares $declared: owns=true reproduces exactly the recipe, so the extra ones are somebody else's"
  fi
  if [ "$owns" = true ] && [ "$dry" = 0 ] && [ "$count" -lt "$declared" ]; then
    refuse "the table on $disk holds $count partitions and the recipe declares $declared: the layout is not on this drive yet"
  fi
  while IFS="$sep" read -r name label fs size type mnt; do
    [ -n "$name" ] || continue
    if [ "$owns" = true ]; then
      node=$(printf '%s\n' "$table" | jq -r ".partitiontable.partitions[$i].node")
    else
      node=""
      held=""
      while read -r candidate _type; do
        [ -n "$candidate" ] || continue
        [ "$(signature "$candidate")" = "$fs" ] || continue
        if [ -z "$label" ] || [ "$(label_of "$candidate")" = "$label" ]; then
          node="$candidate"
          break
        fi
        held="$held $(label_of "$candidate")"
      done <<<"$parts"
      # A partition holding the right filesystem under the wrong label is somebody else's install,
      # and it is named rather than reported as missing.
      [ -n "$node" ] || [ -z "$held" ] ||
        refuse "recipe entry $name: $disk has $fs labelled${held}, which is not the label the recipe declares"
    fi
    [ -n "$node" ] && [ "$node" != null ] ||
      refuse "recipe entry $name: no partition on $disk holds $fs${label:+ labelled $label}"

    sig=$(signature "$node")
    [ "$sig" = "$fs" ] || refuse "recipe entry $name: $node holds ${sig:-nothing}, not $fs"
    got=$(label_of "$node")
    if [ -n "$label" ] && [ "$got" != "$label" ]; then
      refuse "recipe entry $name: $node is labelled ${got:-nothing}, the recipe says $label"
    fi

    end=$(printf '%s\n' "$table" | jq -r --arg node "$node" '.partitiontable.partitions[] | select(.node == $node) | .start + .size')
    # An entry with no size asks for nothing: the partition it adopts is whatever it is. The size the
    # partition has is read off the table, not from lsblk, which knows nothing about a partition of a
    # file-backed fixture.
    if [ -n "$size" ]; then
      want=$(size_bytes "$size")
      if [ "$want" = rest ]; then
        [ "$end" -ge $((disk_bytes / 512 - align)) ] ||
          refuse "recipe entry $name: $node stops at sector $end and the usable drive ends at $((disk_bytes / 512 - align))"
      else
        sect=$(printf '%s\n' "$table" | jq -r --arg node "$node" '.partitiontable.partitions[] | select(.node == $node) | .size')
        [ $((sect * 512)) -ge "$want" ] ||
          refuse "recipe entry $name: $node holds $((sect * 512)) bytes and the recipe asks for $size"
      fi
    fi
    if [ "$owns" = true ] && [ -n "$type" ]; then
      local held
      held=$(printf '%s\n' "$table" | jq -r ".partitiontable.partitions[$i].type")
      [ "${held^^}" = "$(type_guid "$type")" ] ||
        refuse "recipe entry $name: $node is type $held, the recipe says $type"
    fi
    i=$((i + 1))
  done <<<"$entries"
}

# owned_run — reproduce a whole drive (ADR-b77ec913151f owned mode): one fresh GPT laid out to the
# recipe's sizes, then the filesystems the recipe names, then the staging mount. The table write and
# every mkfs sit behind a confirm of their own; --force is the only non-interactive answer.
# create_subvolumes <dir> — the btrfs subvolume tree the host's fileSystems mounts (ADR-eaca61b8):
# @ is what NixOS mounts at /, @nix is where deploy puts the store, @swap is created but never
# mounted. The names come from the layout parity the ADR fixes, not from the recipe: a recipe declares
# partitions and filesystems, and this is the content of one of them. Each one is asked for with
# `btrfs subvolume show` first, so a tree that already exists is adopted rather than recreated.
create_subvolumes() {
  local sub
  for sub in @ @home @nix @log @cache @snapshots @swap; do
    run btrfs subvolume show "$1/$sub" >/dev/null 2>&1 || run btrfs subvolume create "$1/$sub"
  done
}

owned_run() {
  local name label fs size type mnt need sect pos plan node i src root_node adopted declared current opts
  pos=$align
  plan=""
  while IFS="$sep" read -r name label fs size type mnt; do
    [ -n "$name" ] || continue
    [ -n "$size" ] || refuse "owns=true needs a size on $name: a partition being created cannot be sizeless"
    need=$(size_bytes "$size")
    if [ "$need" = rest ]; then
      sect=$((disk_bytes / 512 - align - pos))
    else
      sect=$((need / 512))
    fi
    printf '%s: create %s (%s)\n' "$name" "$size" "$fs"
    plan="$plan$name$sep$pos$sep$sect$sep$(type_guid "${type:-$(default_type "$fs")}")$sep${label:-$name}$sep$fs$sep$mnt"$'\n'
    pos=$(((pos + sect + align - 1) / align * align))
  done <<<"$entries"
  [ "$pos" -le $((disk_bytes / 512 - align)) ] ||
    refuse "the layout the recipe declares needs more than $disk holds: resize is never attempted"

  # The table is written only when the drive does not already hold exactly the layout the recipe
  # declares. Reproducing a layout that is already there changes nothing, and rewriting a table whose
  # partitions are mounted is what sfdisk refuses outright -- which is how a second run of the same
  # recipe used to die.
  declared=$(printf '%s\n' "$plan" | jq -R -s -c '
    split("\n") | map(select(length > 0)) |
    map(split("\u001f") | {start: (.[1] | tonumber), size: (.[2] | tonumber), type: .[3], name: .[4]})')
  adopted=0
  if [ -n "$table" ]; then
    current=$(printf '%s\n' "$table" | jq -c '
      .partitiontable.partitions | map({start, size, type: (.type | ascii_upcase), name})' 2>/dev/null || true)
    [ "$current" = "$declared" ] && adopted=1
  fi

  if [ "$adopted" = 1 ]; then
    say "$disk already holds the layout the recipe declares — the table is not rewritten"
  else
    src=$(findmnt -n -o SOURCE "$mount" 2>/dev/null || true)
    if [ -n "$src" ]; then
      case "$src" in
      "$disk"*) refuse "$mount is mounted from $src: unmount it before terraform.sh rewrites the table on $disk" ;;
      esac
    fi
    confirm "write a fresh GPT partition table on $disk: every partition currently on it is gone" || exit 2
    # sfdisk takes the layout on stdin. A here-string rather than a pipe: in a dry run nothing reads
    # stdin, and a pipe would kill the writer with SIGPIPE. --force is what lets sfdisk overwrite a
    # table that is already there; without it sfdisk asks a question this run has no terminal to answer.
    layout=$(while IFS="$sep" read -r _name start sect type _label _fs _mnt; do
      [ -n "$_name" ] || continue
      printf '%s %s %s\n' "$start" "$sect" "$type"
    done <<<"$plan")$'\n'
    sf=()
    if [ "$force" = 1 ]; then sf+=(--force); fi
    run sfdisk "${sf[@]}" -X gpt "$disk" <<<"$layout"

    # Partition nodes only exist once the table is written, and their names are the kernel's, not ours
    # to guess. In a dry run there is no table to read, so the plan is printed against placeholder names.
    if [ "$dry" = 1 ]; then
      table=''
    else
      table=$(sfdisk --json "$disk" 2>/dev/null) || refuse "sfdisk wrote no readable partition table on $disk"
    fi
  fi
  parts=$(printf '%s\n' "$table" | jq -r '.partitiontable.partitions[] | "\(.node) \(.type)"')
  i=0
  root_node=""
  while IFS="$sep" read -r name start sect type label fs mnt; do
    [ -n "$name" ] || continue
    if [ "$dry" = 1 ]; then
      node="${disk}p$((i + 1))"
    else
      node=$(printf '%s\n' "$table" | jq -r ".partitiontable.partitions[$i].node")
    fi
    # An adopted table already carries the names the recipe declares; setting them again would be a
    # write to a partition this run did not create.
    if [ "$adopted" = 0 ]; then
      run sfdisk --part-label "$disk" "$((i + 1))" "$label" >/dev/null
    fi
    sig=$(signature "$node")
    # owns=true claims the partition, so anything in it that is not the filesystem the recipe declares
    # is this run's to overwrite -- with mkfs -f, because a rewritten table leaves the old superblocks.
    fresh=0
    if [ "$sig" != "$fs" ]; then fresh=1; fi
    if [ "$mnt" = / ]; then
      root_node="$node"
    fi
    format_blank "$node" "$fs" "/dev/disk/by-label/$label" "$sig" "$fresh" || exit 2
    i=$((i + 1))
  done <<<"$plan"
  [ -n "$root_node" ] || refuse "recipe declares no partition mounting /"

  # Mounting is not destructive, so it is not prompted.
  opts=$(mount_opts "$root_fs" "$root_opts")
  mounted_now=0
  if findmnt -n -o SOURCE "$mount" >/dev/null 2>&1; then
    say "$mount already mounted — adopted, not rebuilt"
  else
    if [ -n "$opts" ]; then
      run mount -o "$opts" "$root_node" "$mount"
    else
      run mount "$root_node" "$mount"
    fi
    mounted_now=1
  fi

  # The tree is the content of the root filesystem, so an adopted root that lacks it is the same gap
  # the host's config would hit at boot: @ is what / mounts, @nix is where deploy puts the store, and
  # the others are mounts the config declares. Creation is idempotent (`show` first), and the
  # siblings of @ can only be made with the filesystem root mounted, so the mount is switched here
  # rather than trusted.
  if [ "$root_fs" = btrfs ] && [ "$dry" = 0 ]; then
    src=$(findmnt -n -o SOURCE "$mount" 2>/dev/null || true)
    src=${src%%\[*}
    [ -z "$src" ] || [ "$src" = "$root_node" ] ||
      refuse "$mount is mounted from ${src:-nothing}, not the root partition $root_node: terraform.sh will not lay a subvolume tree into somebody else's mount"
    if [ -n "$src" ]; then
      run umount "$mount"
    fi
    run mount "$root_node" "$mount"
    create_subvolumes "$mount"
    run umount "$mount"
    run mount -o "subvol=@${opts:+,$opts}" "$root_node" "$mount"
    mounted_now=1
  fi

  # Every other mount the recipe declares lives under $mount too, so the installer has an ESP to
  # write its boot loader into.
  i=0
  while IFS="$sep" read -r entry_name _p _s _t _l entry_fs entry_mnt; do
    [ -n "$entry_name" ] || continue
    if [ "$dry" = 1 ]; then
      node="${disk}p$((i + 1))"
    else
      node=$(printf '%s\n' "$table" | jq -r ".partitiontable.partitions[$i].node")
    fi
    i=$((i + 1))
    [ -n "$entry_mnt" ] && [ "$entry_mnt" != / ] || continue
    mount_extra "$node" "$mount$entry_mnt" "$entry_fs" "$(recipe_opts "$entry_name")"
  done <<<"$plan"

  # A dry run wrote nothing, so there is no drive to re-read: the plan printed above is the answer.
  if [ "$dry" = 1 ]; then return; fi
  verify_recipe
  # Only a mount this run made is checked: a mount it adopted belongs to whoever set it up.
  if [ "$mounted_now" = 1 ]; then
    verify_mount "$root_node"
  fi
}

# The staging mount has to resolve to the root entry, not to something else that happens to sit at
# that directory (a scratch tmpfs, another install's volume).
verify_mount() {
  local src
  src=$(findmnt -n -o SOURCE "$mount" 2>/dev/null || true)
  # A subvolume mount reports the subvolume alongside the device (`/dev/loop1p2[/@]`), so the device
  # is what is compared here.
  src=${src%%\[*}
  [ "$src" = "$1" ] ||
    refuse "the staging mount $mount resolves to ${src:-nothing}, not the root partition $1"
}

# --verify is read-only: it reports whether the drive currently satisfies the recipe, and writes
# nothing.
if [ -n "$verify" ]; then
  verify_recipe
  printf 'terraform: recipe satisfied on %s\n' "$disk"
  exit 0
fi

if [ "$owns" = true ]; then
  owned_run
  exit 0
fi

# The ESP is the partition the host's /boot names when that name resolves here; failing that, the
# one already holding a vfat signature, and failing that a blank one whose GPT type says FAT32 or an
# ESP. Anything else on the drive is not ours to look at.
# Flags mode names a filesystem and two device paths; a recipe names entries, and every entry is
# resolved below rather than by a device path that moves between machines.
decision() { [ -n "$1" ] && printf 'adopt' || printf 'format %s' "$2"; }
add_pending() { pending+=("$1$sep$2$sep$3"); }
esp=""
esp_sig=""
root_part=""
root_sig=""
pending=()
plan=()
if [ -z "$recipe" ]; then
  # The ESP is the partition the host's /boot names when that name resolves here; failing that, the
  # one already holding a vfat signature, and failing that a blank one whose GPT type says ESP. A
  # blank Basic Data partition is not a candidate: it says nothing about what it should hold, and
  # formatting one would build a boot partition out of somebody else's reserved space.
  esp=$(declared_node "$esp_device")
  if [ -z "$esp" ]; then
    while read -r node type; do
      [ -n "$node" ] || continue
      if [ "$(signature "$node")" = vfat ]; then
        esp="$node"
        break
      fi
    done <<<"$parts"
    if [ -z "$esp" ]; then
      while read -r node type; do
        [ -n "$node" ] || continue
        case "${type^^}" in
        C12A7328-F81F-11D2-BA4B-00A0C93EC93B | C12A7EA9-344C-4175-A575-202976385741)
          esp="$node"
          break
          ;;
        esac
      done <<<"$parts"
    fi
  fi
  [ -n "$esp" ] ||
    refuse "no FAT partition on $disk: the host's /boot needs a vfat ESP, and terraform.sh will not create one"

  esp_sig=$(signature "$esp")
  if [ -n "$esp_sig" ] && [ "$esp_sig" != vfat ]; then
    refuse "the ESP candidate $esp holds $esp_sig, not vfat: it is not ours to reformat"
  fi

  # The root partition is the one the host's mount names when that name resolves here; failing that,
  # the one carrying the filesystem the host declared. A blank one is a candidate only if its GPT type
  # says a Linux filesystem, so an MSR, an NTFS volume or a swap partition is never picked, and never
  # formatted.
  root_part=$(declared_node "$root_device")
  if [ -z "$root_part" ]; then
    find_root "$parts" "$root_fs" || true
  fi
  if [ -n "$root_part" ]; then
    root_sig=$(signature "$root_part")
    [ -z "$root_sig" ] || [ "$root_sig" = "$root_fs" ] ||
      refuse "$root_part, which $root_device names, holds $root_sig, not $root_fs: it is not ours to mount"
  fi
  if [ -z "$root_part" ]; then
    refuse "no partition on $disk holds $root_fs${seen:+ ($seen)}: a partition another OS owns is never the target, and terraform.sh will not create one"
  fi
  add_pending "$esp" vfat "$esp_device"
  add_pending "$root_part" "$root_fs" "$root_device"
  plan+=("$esp_name: $(decision "$esp_sig" vfat)")
  plan+=("$root_name: $(decision "$root_sig" "$root_fs")")
fi

# free_gaps — the 1MiB-aligned ranges no partition occupies, "<start> <sectors>" per line. The last
# 1MiB of the drive is the backup partition table, so it is never free space.
free_gaps() {
  local total prev start size
  total=$((disk_bytes / 512 - align))
  prev=$align
  while read -r start size; do
    [ -n "$start" ] || continue
    if [ "$prev" -lt "$start" ]; then printf '%s %s\n' "$prev" "$((start - prev))"; fi
    prev=$(((start + size + align - 1) / align * align))
  done <<<"$sorted_parts"
  if [ "$prev" -lt "$total" ]; then printf '%s %s\n' "$prev" "$((total - prev))"; fi
}

# place_creations — every entry nothing on the drive describes, laid into free space in recipe order:
# the first 1MiB-aligned gap large enough, and `rest` whatever is left of the last gap. resize is
# never attempted, so "it does not fit" is the answer rather than a smaller partition. Fills
# creations[] with "<entry index> <name> <start sector> <sectors>"; free-space maths is settled here,
# before a single write (slice R2).
creations=()
gap_start=()
gap_sects=()
place_creations() {
  local n i name label fs size type mnt need sect start placed left last used
  used=()
  for i in "${!gap_sects[@]}"; do used+=("0"); done
  for n in "${!entry_lines[@]}"; do
    if [ -n "${resolved[n]}" ]; then continue; fi
    IFS="$sep" read -r name label fs size type mnt <<<"${entry_lines[n]}"
    [ -n "$size" ] || refuse "$name matches no partition on $disk and declares no size: a partition being created cannot be sizeless"
    need=$(size_bytes "$size")
    last=${#gap_sects[@]}
    if [ "$need" = rest ]; then
      [ "$last" -gt 0 ] || refuse "$name declares rest and there is no free space left on $disk"
      start=$((gap_start[last - 1] + used[last - 1]))
      sect=$((gap_sects[last - 1] - used[last - 1]))
      [ "$sect" -gt 0 ] || refuse "$name declares rest and there is no free space left on $disk"
      used[last - 1]=$((gap_sects[last - 1]))
    else
      sect=$((need / 512))
      placed=0
      for i in "${!gap_sects[@]}"; do
        if [ $((gap_sects[i] - used[i])) -ge "$sect" ]; then
          start=$((gap_start[i] + used[i]))
          used[i]=$((used[i] + sect))
          placed=1
          break
        fi
      done
      if [ "$placed" = 0 ]; then
        left=""
        for i in "${!gap_sects[@]}"; do left="$left $(human_size "$((gap_sects[i] * 512))")"; done
        refuse "$name needs $(human_size "$need") and no free gap holds it (free:${left}) — resize is never attempted"
      fi
    fi
    printf '%s: create %s\n' "$name" "$size"
    creations+=("$n$sep$name$sep$start$sep$sect")
  done
}

# append_creations — write each created entry into the gap it was placed for. Appending an entry is
# the only partition-table change shared mode makes (ADR-c2cd97401185): an entry that already exists
# is never modified, resized, renamed or retyped, and the run proves that by comparing the entries
# that existed before the append with the ones after it.
append_creations() {
  local n idx name start sect fs type guid layout before after
  [ "${#creations[@]}" -gt 0 ] || return 0
  before=$(printf '%s\n' "$table" | jq -c '.partitiontable.partitions')
  for n in "${!creations[@]}"; do
    IFS="$sep" read -r idx name start sect <<<"${creations[n]}"
    IFS="$sep" read -r _name _label fs _size type _mnt <<<"${entry_lines[idx]}"
    guid=$(type_guid "${type:-$(default_type "$fs")}")
    confirm "create a new partition on $disk for $name at sector $start ($(human_size "$((sect * 512))")): free space no partition claims" ||
      exit 2
    layout=$(printf 'start=%d,size=%d,type=%s,name=%s\n' "$start" "$sect" "$guid" "$name")
    # A here-string, not a pipe: in a dry run nothing reads stdin, and a pipe would kill the writer.
    run sfdisk --append "$disk" <<<"$layout"
  done
  table=$(sfdisk --json "$disk" 2>/dev/null) || refuse "sfdisk appended no readable partition table on $disk"
  parts=$(printf '%s\n' "$table" | jq -r '.partitiontable.partitions[] | "\(.node) \(.type)"')
  sorted_parts=$(printf '%s\n' "$table" | jq -r '.partitiontable.partitions | sort_by(.start) | .[] | "\(.start) \(.size)"')
  resolve_entries
  after=$(printf '%s\n' "$table" | jq -c '.partitiontable.partitions')
  [ "$(printf '%s\n' "$after" | jq -c ".[:$(printf '%s\n' "$before" | jq 'length')]")" = "$before" ] ||
    refuse "appending moved an existing partition entry on $disk, which is never allowed"
}

# Recipe mode: resolve every entry, append the ones nothing describes, then treat each resolved
# partition the same way — adopt what holds a filesystem, format only what blkid reports blank.
if [ -n "$recipe" ]; then
  sorted_parts=$(printf '%s\n' "$table" | jq -r '(.partitiontable.partitions // []) | sort_by(.start) | .[] | "\(.start) \(.size)"') ||
    refuse "cannot read the partition table on $disk"
  while read -r start size; do
    [ -n "$start" ] || continue
    gap_start+=("$start")
    gap_sects+=("$size")
  done < <(free_gaps)
  resolve_entries
  # On a drive this host does not own, the ESP is adopted, never appended: adding a boot partition to
  # somebody else's drive is a partition-table change terraform.sh never makes, and appending one
  # before refusing would leave the drive changed with nothing installed. So the ESP is settled here,
  # before a single sector is written.
  esp_idx=""
  for n in "${!entry_lines[@]}"; do
    IFS="$sep" read -r name _ <<<"${entry_lines[n]}"
    [ "$name" = "$esp_name" ] && esp_idx="$n"
  done
  if [ "$owns" != true ] && [ -n "$esp_idx" ] && [ -z "${resolved[$esp_idx]}" ]; then
    refuse "recipe entry $esp_name matches no partition on $disk: $(esp_offers) — declare the label or GPT name the ESP on this drive actually carries"
  fi
  place_creations
  # A dry run plans and writes nothing, so the entries it creates stay creates with no partition.
  if [ "$dry" = 0 ]; then append_creations; fi
  for n in "${!entry_lines[@]}"; do
    node="${resolved[n]}"
    [ -n "$node" ] || continue
    IFS="$sep" read -r name label fs _size _type _mnt <<<"${entry_lines[n]}"
    sig=$(signature "$node")
    plan+=("$name: $(decision "$sig" "$fs")")
    add_pending "$node" "$fs" "${label:+/dev/disk/by-label/$label}"
    case "$name" in
    "$esp_name")
      esp="$node"
      esp_sig="$sig"
      ;;
    "$root_name")
      root_part="$node"
      root_sig="$sig"
      root_fs="$fs"
      ;;
    esac
  done
  # A creation has no node yet, so it resolves to nothing; that is the plan, not a refusal. Only a
  # run that is about to write needs both ends to exist.
  [ -n "$esp" ] || [ "$dry" = 1 ] || refuse "recipe entry $esp_name resolves to no partition on $disk: nothing here is the host's /boot"
  [ -n "$root_part" ] || [ "$dry" = 1 ] || refuse "recipe entry $root_name resolves to no partition on $disk: the root has nowhere to live"
fi

before=$(table_checksum)
before_entries=""
[ -z "$recipe" ] || before_entries=$(printf '%s\n' "$table" | jq -c '.partitiontable.partitions')
check_uuid "$esp" "$esp_device" "$esp_sig"
[ -n "$root_sig" ] || root_sig=$(signature "$root_part")
check_uuid "$root_part" "$root_device" "$root_sig"

# What this run will do, read-only, before any of it.
printf 'terraform: drive %s\n' "$disk"
for line in "${plan[@]}"; do printf '%s\n' "$line"; done

for entry in "${pending[@]}"; do
  IFS="$sep" read -r node fs device <<<"$entry"
  format_blank "$node" "$fs" "$device" "$(signature "$node")" || exit 2
done

# Nothing that already existed may have moved: a recipe run may only add entries, and flags mode may
# not touch the table at all.
if [ -n "$recipe" ]; then
  after=$(sfdisk --json "$disk" 2>/dev/null) || refuse "cannot re-read the partition table on $disk after the run"
  [ "$(printf '%s\n' "$after" | jq -c ".partitiontable.partitions[:$(printf '%s\n' "$before_entries" | jq 'length')]")" = "$before_entries" ] ||
    refuse "the partition entries that already existed on $disk moved during the run, which is never allowed"
elif [ "$(table_checksum)" != "$before" ]; then
  printf 'terraform.sh: the partition table moved during the run, which must never happen\n' >&2
  exit 2
fi

# Mounting is not destructive, so it is not prompted. deploy reads the same precondition.
if findmnt -n -o SOURCE "$mount" >/dev/null 2>&1; then
  say "$mount already mounted — adopted, not rebuilt"
else
  opts=$(mount_opts "$root_fs" "$root_opts")
  if [ -n "$opts" ]; then
    run mount -o "$opts" "$root_part" "$mount"
  else
    run mount "$root_part" "$mount"
  fi
fi

say "terraform: adopted ESP $esp (${esp_sig:-vfat, newly formatted}), root $root_part (${root_sig:-$root_fs, newly formatted})"

# deploy writes the boot loader into efiSysMountPoint, so the ESP has to be mounted where the config
# names it.
if [ -n "$esp" ]; then
  mount_extra "$esp" "$mount/boot" vfat
fi

# The run is not finished until the drive is re-read (spec: verification is the third use of the same
# routine). Flags mode names a filesystem and a device path rather than declaring a recipe, so there
# is nothing to verify against, and a dry run wrote nothing to re-read.
if [ -n "$recipe" ] && [ "$dry" = 0 ]; then
  verify_recipe
  verify_mount "$root_part"
fi
