#!/usr/bin/env bash
# Sourced, never run: the geometry constants below are named by tests/terraform.bats, and $repo and
# $stubs come from helpers.bash, so shellcheck cannot see either use from inside this file.
# shellcheck disable=SC2034,SC2154
# Disk fixtures for tests/terraform.bats: a sparse image whose partitions are real filesystems held
# in files, so terraform.sh runs against real blkid/mkfs/mtools/debugfs with no root and no loop
# device. Every tool it calls takes a plain path, and sfdisk names a partition `<disk><index>`, so a
# slice named `<disk>1` is exactly the node sfdisk reports for image `<disk>` — the fixture never
# needs a flag the shipped script does not have.
#
# Geometry (512-byte sectors). ESP is partition 1 everywhere; Windows disks carry an MSR and an NTFS
# partition before the Linux one, so an index-based selection has to skip them.
#   esp   2048..18431    16384 sectors (8MB)
#   msr   18432..26623    8192 (4MB)   windows only
#   ntfs  26624..42999   16384 (8MB)   windows only
#   root  26624..59391   32768 (16MB)  linux / blank disks
FAT32_TYPE=C12A7EA9-344C-4175-A575-202976385741
LINUX_TYPE=0FC63DAF-8483-4772-8E79-3D69D8457574
MSR_TYPE=E8250974-344C-FF3D-9D17-806509A1E1AA
NTFS_TYPE=0657FE6D-A4A1-43C4-A16B-7172F04D58CD
ESP_START=2048 ESP_END=18431 ESP_N=16384
MSR_START=18432 MSR_END=26623 MSR_N=8192
NTFS_START=26624 NTFS_END=42999 NTFS_N=16384
LINUX_START=26624 LINUX_END=59391 LINUX_N=32768
# A second Linux filesystem on the same drive, so a run that picks by filesystem type alone can be
# shown picking the wrong one.
LINUX2_START=59392 LINUX2_END=92159 LINUX2_N=32768
# On a Windows disk the Linux partition sits after the NTFS volume, so it has its own geometry.
WIN_LINUX_START=43000 WIN_LINUX_END=75767

fixture_dir() { disk_dir="$(mktemp -d)"; }
fixture_teardown() { rm -rf "$disk_dir"; }

# mk_disk <name> — a sparse image. Nothing on disk until a partition is written.
mk_disk() { truncate -s 64M "$disk_dir/$1.img"; }

# partition <disk> <index> <start> <end> <type> <name>
partition() { sgdisk --new="$2:$3:$4" -t "$2:$5" -c "$2:$6" "$disk_dir/$1.img" >/dev/null; }

# slice <disk> <index> <start> <count> — the partition as its own file, named as sfdisk names it.
slice() { dd if="$disk_dir/$1.img" of="$disk_dir/$1.img$2" bs=512 skip="$3" count="$4" status=none; }

# adopt <disk> <index> — the slice written back into the image, which is what a real mkfs would do
# to a real partition.
adopt() { dd if="$disk_dir/$1.img$2" of="$disk_dir/$1.img" bs=512 seek="$3" count="$4" conv=notrunc status=none; }

table_checksum() { dd if="$disk_dir/$1.img" bs=1M count=1 status=none | md5sum | cut -d' ' -f1; }
region_checksum() { dd if="$disk_dir/$1.img" bs=512 skip="$2" count="$3" status=none | md5sum | cut -d' ' -f1; }

# seed_region <disk> <start> <count> <byte> — recognizable bytes in a partition another OS owns, so a
# checksum that moves means the region was actually written rather than that it happens to be zeros.
seed_region() {
  dd if=/dev/zero bs=1 count="$3" | tr '\0' "$4" | dd of="$disk_dir/$1.img" bs=1 seek="$2" conv=notrunc status=none
}
type_of() { blkid -o value -s TYPE "$disk_dir/$1.img$2" 2>/dev/null || true; }
label_of() { blkid -o value -s LABEL "$disk_dir/$1.img$2" 2>/dev/null || true; }

# A vfat ESP holding the boot metadata another OS needs, written through mtools because the ESP is a
# file here. mtools creates no directory a caller has not made, so every level goes in first.
# <dir> is the path inside the ESP, e.g. Microsoft/BOOT or systemd.
esp_foreign() {
  local disk="$1" dir="$2"
  slice "$disk" 1 "$ESP_START" "$ESP_N"
  mkfs.vfat -F 32 "$disk_dir/$disk.img1" >/dev/null 2>&1
  local path="::/EFI" level
  mmd -i "$disk_dir/$disk.img1" "$path"
  IFS=/ read -r -a comps <<<"$dir"
  for level in "${comps[@]}"; do
    path="$path/$level"
    mmd -i "$disk_dir/$disk.img1" "$path"
  done
  printf '%s-BOOT\n' "$dir" >"$disk_dir/loader.efi"
  mcopy -i "$disk_dir/$disk.img1" "$disk_dir/loader.efi" "$path/boot.efi"
  adopt "$disk" 1 "$ESP_START" "$ESP_N"
}

# mkfs on a slice then put it back, so the image holds a real filesystem at the partition offset.
format_slice() { # <disk> <index> <start> <count> <fs> [label]
  local disk="$1" idx="$2" start="$3" count="$4" fs="$5" label="${6:-}"
  slice "$disk" "$idx" "$start" "$count"
  if [ -n "$label" ]; then
    case "$fs" in
      vfat) mkfs.vfat -F 32 -n "$label" "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      ext4) mkfs.ext4 -q -T ext4 -L "$label" "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
    esac
  else
    case "$fs" in
      vfat) mkfs.vfat -F 32 "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      ext4) mkfs.ext4 -q -T ext4 "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
    esac
  fi
  adopt "$disk" "$idx" "$start" "$count"
}

# Root data another install owns, written into the filesystem itself rather than the image.
root_data() { printf 'KEEP\n' >"$disk_dir/keep.txt"; debugfs -w -R "write $disk_dir/keep.txt /keep.txt" "$disk_dir/$1.img2" >/dev/null 2>&1; }

# nodes <disk> — create the partition files sfdisk names for this image. A real disk always has
# these nodes; a fixture has to make them, out of the image region each partition covers. A blank
# partition comes out as zeros, which is exactly what blkid reads as no signature.
nodes() {
  while read -r node start size; do
    dd if="$disk_dir/$1.img" of="$node" bs=512 skip="$start" count="$size" status=none
  done < <(sfdisk --json "$disk_dir/$1.img" | jq -r '.partitiontable.partitions[] | "\(.node) \(.start) \(.size)"')
}

# sync <disk> — the partitions written back into the image, which is what a real mkfs does to a real
# partition. It is what lets a second run see the first run's work instead of the original zeros.
sync() {
  while read -r node start size; do
    dd if="$node" of="$disk_dir/$1.img" bs=512 seek="$start" count="$size" conv=notrunc status=none
  done < <(sfdisk --json "$disk_dir/$1.img" | jq -r '.partitiontable.partitions[] | "\(.node) \(.start) \(.size)"')
}

# terraform_run — the shipped script against the fixture. mount and findmnt stay stubbed (they take
# root); sgdisk, wipefs, parted and fdisk are stubbed to fail, so a partition write is caught on the
# call log instead of silently tolerated.
terraform_run() {
  local disk="$1"
  shift
  nodes "$disk"
  PATH="$stubs:$PATH" INSTALL_FORCE="${TF_FORCE:-1}" bash "$repo/terraform.sh" \
    --disk "$disk_dir/$disk.img" --mount "$disk_dir/mnt" --root-fs "${TF_ROOT_FS:-ext4}" \
    --root-device "${TF_ROOT_DEV:-/dev/disk/by-label/nixos}" \
    --esp-device "${TF_ESP_DEV:-/dev/disk/by-label/boot}" "$@"
}
