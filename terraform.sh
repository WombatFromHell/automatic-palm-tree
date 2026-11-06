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
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/confirm.sh
. lib/confirm.sh

disk=""
mount="/mnt"
root_fs="ext4"
root_device=""
esp_device=""
dry=0
force="${INSTALL_FORCE:-0}"

usage() {
  printf 'usage: terraform.sh [--dry-run] [--force] --disk <drive> --mount <dir> --root-fs <type> --root-device <path> --esp-device <path>\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) dry=1 ;;
  --force) force=1 ;;
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

if [ -z "$disk" ] || [ -z "$root_device" ] || [ -z "$esp_device" ]; then
  usage >&2
  exit 2
fi

refuse() {
  printf 'terraform.sh: %s\n' "$*" >&2
  exit 2
}

# A partition with a signature is somebody else's filesystem or somebody else's data; a partition
# without one is space we may fill. blkid exits non-zero when it finds nothing, which is the answer.
signature() { blkid -o value -s TYPE "$1" 2>/dev/null || true; }

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

# Only the first megabyte: a mkfs writes at the partition's own offset, and a partition that starts
# at sector 2048 begins exactly there, so widening the window would fail a run that touched nothing.
table_checksum() { dd if="$disk" bs=1M count=1 status=none | md5sum | cut -d' ' -f1; }

command -v sfdisk >/dev/null || refuse "sfdisk is required to read the partition table"
table=$(sfdisk --json "$disk" 2>/dev/null) ||
  refuse "no partition table on $disk: terraform.sh never partitions a drive it does not own — create the ESP and the root partition first"
parts=$(printf '%s\n' "$table" | jq -r '.partitiontable.partitions[] | "\(.node) \(.type)"' 2>/dev/null) ||
  refuse "jq is required to read the partition table"
[ -n "$parts" ] || refuse "no partitions on $disk: terraform.sh never partitions a drive it does not own"
nodes=$(printf '%s\n' "$parts" | cut -d' ' -f1)

# The ESP is the partition the host's /boot names when that name resolves here; failing that, the
# one already holding a vfat signature, and failing that a blank one whose GPT type says FAT32 or an
# ESP. Anything else on the drive is not ours to look at.
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
      C12A7EA9-344C-4175-A575-202976385741 | B461F200-2D0D-4F87-B71B-0D421BA668D7)
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
  seen=""
  while read -r node type; do
    [ -n "$node" ] || continue
    sig=$(signature "$node")
    if [ -n "$sig" ]; then
      if [ "$sig" = "$root_fs" ]; then
        root_part="$node"
        break
      fi
      seen="$seen $sig"
      continue
    fi
    case "${type^^}" in
    0FC63DAF-8483-4772-8E79-3D69D8457574 | EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
      root_part="$node"
      break
      ;;
    esac
  done <<<"$parts"
fi
if [ -n "$root_part" ]; then
  root_sig=$(signature "$root_part")
  [ -z "$root_sig" ] || [ "$root_sig" = "$root_fs" ] ||
    refuse "$root_part, which $root_device names, holds $root_sig, not $root_fs: it is not ours to mount"
fi
if [ -z "$root_part" ]; then
  refuse "no partition on $disk holds $root_fs${seen:+ ($seen)}: a partition another OS owns is never the target, and terraform.sh will not create one"
fi

# A blank partition the host names by UUID is refused before anything is written, so a run that
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
  local node="$1" fs="$2" device="$3" sig="$4"
  [ -n "$sig" ] && return 0

  local label=""
  case "$device" in /dev/disk/by-label/*) label="${device##*/}" ;; esac

  confirm "format $node as $fs: every byte currently in it is gone" || return 2

  local args=()
  case "$fs" in
  vfat)
    args=(-F 32)
    [ -n "$label" ] && args+=(-n "$label")
    ;;
  ext4)
    args=(-q)
    [ -n "$label" ] && args+=(-L "$label")
    ;;
  btrfs)
    [ -n "$label" ] && args+=(-L "$label")
    ;;
  *) refuse "terraform.sh does not know how to format $fs" ;;
  esac
  run "mkfs.$fs" "${args[@]}" "$node"
}

before=$(table_checksum)
check_uuid "$esp" "$esp_device" "$esp_sig"
[ -n "$root_sig" ] || root_sig=$(signature "$root_part")
check_uuid "$root_part" "$root_device" "$root_sig"
format_blank "$esp" vfat "$esp_device" "$esp_sig" || exit 2
format_blank "$root_part" "$root_fs" "$root_device" "$root_sig" || exit 2

if [ "$(table_checksum)" != "$before" ]; then
  printf 'terraform.sh: the partition table moved during the run, which must never happen\n' >&2
  exit 2
fi

# Mounting is not destructive, so it is not prompted. deploy reads the same precondition.
if findmnt -n -o SOURCE "$mount" >/dev/null 2>&1; then
  say "$mount already mounted — adopted, not rebuilt"
else
  run mount "$root_part" "$mount"
fi

say "terraform: adopted ESP $esp (${esp_sig:-vfat, newly formatted}), root $root_part (${root_sig:-$root_fs, newly formatted})"
