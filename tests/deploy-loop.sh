#!/usr/bin/env bash
# Deployment harness on a REAL loop device: the parts the fixture tier cannot do, because it has no
# root -- real lsblk, real /dev/loop0pN nodes, real mkfs on partitions, real mount, real filesystem
# labels. It touches only sparse images it creates; it never touches a real disk.
#
#   sudo nix develop --command bash tests/deploy-loop.sh [logfile]
#
# Image size defaults to 4G; override with DEPLOY_LOOP_SIZE=8G.
#
# Root is required for losetup and mount (measured: both Permission denied as uid 1000, even inside
# `unshare -r -m`). Nix supplies sgdisk/mkfs/lsblk/blkid/mcopy/jq. Not part of tests/run.sh, which
# stays root-free.
set -uo pipefail

if [ "$(id -u)" != 0 ]; then
  printf 'deploy-loop: needs root for losetup and mount — sudo nix develop --command bash %s\n' "$0" >&2
  exit 1
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
log=${1:-/tmp/terraform-loop-deploy.log}
# Not `size`: `nix develop` exports a stray `SIZE=size` in this shell, and `${SIZE:-4G}` would then
# hand truncate the word "size".
disk_size=${DEPLOY_LOOP_SIZE:-4G}
LINUX_TYPE='0FC63DAF-8483-4772-8E79-3D69D8457574'
ESP_TYPE='C12A7EA9-344C-4175-A575-202976385741'
MSR_TYPE='E8250974-344C-FF3D-9D17-806509A1E1AA'
NTFS_TYPE='0657FE6D-A4A1-43C4-A16B-7172F04D58CD'

main() {
  pass=0 fail=0 pending=0
  work=$(mktemp -d)
  img="$work/loop.img"
  mount_dir="$work/mnt"
  owned_dir="$work/owned"
  mkdir -p "$mount_dir" "$owned_dir" "$work/efi/Microsoft/BOOT"
  truncate -s "$disk_size" "$img" "$work/owned.img"
  # --show is required: util-linux establishes the loop silently and prints nothing without it.
  DEV=$(losetup -f --partscan --show "$img")
  owned_dev=$(losetup -f --partscan --show "$work/owned.img")
  # Never proceed on a device we did not create: this harness must only ever touch its own images.
  if [ "$DEV" = "$owned_dev" ] ||
    ! lsblk -n -o NAME "$DEV" 2>/dev/null | grep -q '^loop' ||
    ! lsblk -n -o NAME "$owned_dev" 2>/dev/null | grep -q '^loop'; then
    printf 'deploy-loop: could not create loop devices (got "%s" and "%s")\n' "$DEV" "$owned_dev"
    exit 1
  fi
  # -O, not -o: in losetup `-o`/`-n` are byte offsets, so `-o BACKING_FILE` parses as an offset and
  # prints nothing, which would read as "not our device" on a device that is ours.
  if [ "$(losetup -l -O BACK-FILE --noheadings "$DEV" 2>/dev/null)" != "$img" ]; then
    printf 'deploy-loop: %s is not backed by %s — refusing to partition a device we did not create\n' "$DEV" "$img"
    exit 1
  fi
  esp="$DEV"p1 msr="$DEV"p2 ntfs="$DEV"p3 root="$DEV"p4
  # A recipe pins the loop device with --disk here because a real machine also has real disks and
  # discovery would refuse to choose. On a host the recipe names no disk at all.
  printf 'device %s backed by %s (%s)\n' "$DEV" "$img" "$disk_size"
  cleanup() {
    umount "$mount_dir" "$owned_dir" "$work/mnt-dos" "$work/mnt-append" 2>/dev/null || true
    losetup -d "$DEV" "$owned_dev" "${dos_dev:-}" "${ap_dev:-}" 2>/dev/null || true
    rm -rf "$work"
  }
  # The device and the image must not outlive a run that stops early, which is exactly how the first
  # run leaked two attached loop devices.
  trap cleanup EXIT

  # Partition starts come from the table itself, never from constants: sfdisk lays out GPT entries
  # sequentially and aligns them, so a hardcoded sector number would drift.
  start_of() { sfdisk --json "$DEV" | jq -r ".partitiontable.partitions[$1-1].start"; }
  region() { dd if="$DEV" bs=512 "skip=$(start_of "$1")" count=2048 2>/dev/null | md5sum | cut -d' ' -f1; }

  # 1. A drive with no partition table has nothing to emit: exit 2, and no JSON written at all.
  cd "$repo" && ./terraform.sh --emit --disk "$DEV" >"$work/emit.out" 2>"$work/emit.err"
  rc=$?
  if [ "$rc" = 2 ] && [ ! -s "$work/emit.out" ] && grep -q 'no partition table' "$work/emit.err"; then
    pass=$((pass + 1))
    printf 'PASS emit refuses a tableless drive and writes no JSON: %s\n' "$(cat "$work/emit.err")"
  else
    fail=$((fail + 1))
    printf 'FAIL emit on a tableless drive (exit %s, %s bytes of JSON)\n%s\n' "$rc" "$(wc -c <"$work/emit.out")" "$(cat "$work/emit.err")"
  fi

  # 2. A Windows-shaped drive: ESP carrying a loader, an MSR, an NTFS region, a blank Linux
  #    partition. Nothing here is terraform.sh's doing.
  loader="$work/loader.bin"
  dd if=/dev/urandom of="$loader" bs=4096 count=1 status=none
  # --label=gpt is not optional: sfdisk on an empty drive makes a DOS disklabel, and MBR type codes
  # silently drop every GUID this harness is meant to put on the drive.
  sfdisk --label=gpt "$DEV" >/dev/null 2>&1 <<EOF
size=16M,type=$ESP_TYPE,name="EFI System Partition"
size=16M,type=$MSR_TYPE,name="Microsoft reserved partition"
size=32M,type=$NTFS_TYPE,name="Basic data partition"
type=$LINUX_TYPE,name="Linux filesystem"
EOF
  [ -b "$root" ] || losetup -R "$DEV" 2>/dev/null || true
  [ -b "$root" ] || {
    printf 'deploy-loop: no partition nodes on %s after sfdisk\n' "$DEV"
    exit 1
  }
  mkfs.vfat -F 32 "$esp" >/dev/null 2>&1
  cp "$loader" "$work/efi/Microsoft/BOOT/boot.efi"
  mcopy -s -i "$esp" "$work/efi" ::/EFI >/dev/null 2>&1
  dd if=/dev/zero of="$root" bs=1M count=2 status=none
  dd if=/dev/zero of="$msr" bs=1M count=1 status=none
  dd if=/dev/zero of="$ntfs" bs=1M count=1 status=none
  esp_before=$(region 1)
  msr_before=$(region 2)
  ntfs_before=$(region 3)
  table_before=$(sfdisk --json "$DEV")

  # 3. --emit on a real drive finds the ESP only, and names what it left out.
  out=$(cd "$repo" && ./terraform.sh --emit --disk "$DEV" 2>/dev/null)
  rc=$?
  fs=$(printf '%s' "$out" | jq -c '.partitions | map(.fs)')
  if [ "$rc" = 0 ] && [ "$fs" = '["vfat"]' ]; then
    pass=$((pass + 1))
    printf 'PASS emit on a real drive emits the ESP only: %s\n' "$fs"
  else
    fail=$((fail + 1))
    printf 'FAIL emit on a real drive (exit %s, filesystems %s)\n%s\n' "$rc" "$fs" "$out"
  fi

  # 4. The operator adds the one partition the drive cannot describe, and the recipe deploys: the
  #    ESP is adopted, the blank partition is formatted, and the run mounts it for real.
  printf '%s\n' "$out" | jq '.partitions += [{name: "root", label: "nixos", fs: "ext4", size: "2G", mount: "/"}]' >"$work/recipe.json"
  out=$(cd "$repo" && ./terraform.sh --recipe "$work/recipe.json" --disk "$DEV" --mount "$mount_dir" --force 2>&1)
  rc=$?
  src=$(findmnt -n -o SOURCE "$mount_dir" 2>/dev/null || true)
  label=$(blkid -o value -s LABEL "$root" 2>/dev/null || true)
  fs_root=$(blkid -o value -s TYPE "$root" 2>/dev/null || true)
  if [ "$rc" = 0 ] && [ "$src" = "$root" ] && [ "$label" = nixos ] && [ "$fs_root" = ext4 ]; then
    pass=$((pass + 1))
    printf 'PASS recipe deploy: %s mounted at %s (ext4, label %s)\n' "$src" "$mount_dir" "$label"
  else
    fail=$((fail + 1))
    printf 'FAIL recipe deploy (exit %s, source %s, label %s, signature %s)\n%s\n' "$rc" "$src" "$label" "$fs_root" "$out"
  fi

  # 5. Windows bytes survive: the loader is still in the ESP and the foreign regions are unchanged.
  mcopy -i "$esp" ::/EFI/Microsoft/BOOT/boot.efi "$work/loader.read" >/dev/null 2>&1
  if cmp -s "$loader" "$work/loader.read" &&
    [ "$(region 1)" = "$esp_before" ] && [ "$(region 2)" = "$msr_before" ] &&
    [ "$(region 3)" = "$ntfs_before" ] && [ "$(sfdisk --json "$DEV")" = "$table_before" ]; then
    pass=$((pass + 1))
    printf 'PASS foreign regions byte-identical, partition table unchanged\n'
  else
    fail=$((fail + 1))
    printf 'FAIL foreign bytes or partition table changed (esp %s/%s msr %s/%s ntfs %s/%s)\n' \
      "$(region 1)" "$esp_before" "$(region 2)" "$msr_before" "$(region 3)" "$ntfs_before"
  fi

  # 6. Re-running the same recipe plans nothing new: no format line, no byte moved.
  out=$(cd "$repo" && ./terraform.sh --recipe "$work/recipe.json" --disk "$DEV" --mount "$mount_dir" --force 2>&1)
  rc=$?
  formats=$(printf '%s' "$out" | grep -c 'format ')
  if [ "$rc" = 0 ] && [ "$formats" = 0 ] && [ "$(region 1)" = "$esp_before" ]; then
    pass=$((pass + 1))
    printf 'PASS second run formats nothing (plan: %s)\n' "$(printf '%s' "$out" | grep -E 'adopt|format' | tr '\n' ' ')"
  else
    fail=$((fail + 1))
    printf 'FAIL second run (exit %s, format lines %s)\n%s\n' "$rc" "$formats" "$out"
  fi

  # 7. Owned mode on a fresh drive: terraform.sh writes the table itself, formats both partitions,
  #    mounts the root, and lays down the subvolume tree the host's config mounts. The names are the
  #    layout ADR-eaca61b8 fixes (@, @nix, @home...), not names derived from the recipe, and / is
  #    mounted as the @ subvolume with the options hosts/<host>/nixos.nix uses. @nix is a sibling of
  #    @, so it is checked in the subvolume list rather than as a directory inside the mount.
  cat >"$work/owned.json" <<EOF
{"owns": true, "partitions": [
  {"name": "boot", "label": "boot", "fs": "vfat", "size": "8M", "mount": "/boot"},
  {"name": "nixos", "label": "nixos", "fs": "btrfs", "size": "2G", "mount": "/"}
]}
EOF
  out=$(cd "$repo" && ./terraform.sh --recipe "$work/owned.json" --disk "$owned_dev" --mount "$owned_dir" --force 2>&1)
  rc=$?
  [ -b "$owned_dev"p2 ] || losetup -R "$owned_dev" 2>/dev/null || true
  entries=$(sfdisk --json "$owned_dev" 2>/dev/null | jq '.partitiontable.partitions | length' 2>/dev/null || echo none)
  esp_fs=$(blkid -o value -s TYPE "$owned_dev"p1 2>/dev/null || true)
  esp_label=$(blkid -o value -s LABEL "$owned_dev"p1 2>/dev/null || true)
  subs=$(btrfs subvolume list "$owned_dir" 2>/dev/null | awk '{print $NF}' | sort | tr '\n' ' ')
  src=$(findmnt -n -o SOURCE "$owned_dir" 2>/dev/null || true)
  opts=$(findmnt -n -o OPTIONS "$owned_dir" 2>/dev/null || true)
  if [ "$rc" = 0 ] && [ "$entries" = 2 ] && [ "$esp_fs" = vfat ] && [ "$esp_label" = boot ] &&
    printf '%s' "$subs" | grep -q '@nix' && printf '%s' "$subs" | grep -q '@home' &&
    printf '%s' "$opts" | grep -q 'noatime' && printf '%s' "$opts" | grep -q 'compress=zstd' &&
    [ "$src" = "$owned_dev"'p2[/@]' ]; then
    pass=$((pass + 1))
    printf 'PASS owned mode reproduces the recipe: 2 partitions, ESP %s/%s, subvolumes %s, root mounted from %s (%s)\n' \
      "$esp_fs" "$esp_label" "$subs" "$src" "$opts"
  else
    fail=$((fail + 1))
    printf 'FAIL owned mode (exit %s, partitions %s, ESP %s/%s, subvolumes %s, mount %s)\n%s\n' \
      "$rc" "$entries" "$esp_fs" "$esp_label" "$subs" "$src" "$out"
  fi
  owned_table=$(sfdisk --json "$owned_dev" 2>/dev/null)
  owned_subs=$(btrfs subvolume list "$owned_dir" 2>/dev/null | grep -c '@')

  # 8. Re-running the owned recipe on the same drive changes nothing: the table is already there, so
  #    this is shared mode, and deploy reads the same subvolumes back.
  out=$(cd "$repo" && ./terraform.sh --recipe "$work/owned.json" --disk "$owned_dev" --mount "$owned_dir" --force 2>&1)
  rc=$?
  formats=$(printf '%s' "$out" | grep -c 'format ')
  if [ "$rc" = 0 ] && [ "$formats" = 0 ] && [ "$(sfdisk --json "$owned_dev" 2>/dev/null)" = "$owned_table" ] &&
    [ "$(btrfs subvolume list "$owned_dir" 2>/dev/null | grep -c '@')" = "$owned_subs" ]; then
    pass=$((pass + 1))
    printf 'PASS second owned run is idempotent (format lines %s, subvolumes %s, table unchanged)\n' "$formats" "$owned_subs"
  else
    fail=$((fail + 1))
    printf 'FAIL second owned run (exit %s, format lines %s, subvolumes %s)\n%s\n' "$rc" "$formats" "$(btrfs subvolume list "$owned_dir" 2>/dev/null | grep -c '@')" "$out"
  fi

  # 9. A DOS partition table is refused before anything is written, and the drive is left alone.
  dos="$work/dos.img"
  truncate -s 64M "$dos"
  dos_dev=$(losetup -f --partscan --show "$dos")
  sfdisk --label=dos "$dos_dev" >/dev/null 2>&1 <<EOF
size=8M,type=0x07
EOF
  before=$(dd if="$dos_dev" bs=512 count=1 2>/dev/null | md5sum | cut -d' ' -f1)
  out=$(cd "$repo" && ./terraform.sh --recipe "$work/owned.json" --disk "$dos_dev" --mount "$work/mnt-dos" --force 2>&1)
  rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'is dos, not gpt' &&
    [ "$(dd if="$dos_dev" bs=512 count=1 2>/dev/null | md5sum | cut -d' ' -f1)" = "$before" ]; then
    pass=$((pass + 1))
    printf 'PASS owned mode refuses a DOS partition table and writes nothing\n'
  else
    fail=$((fail + 1))
    printf 'FAIL DOS refusal (exit %s)\n%s\n' "$rc" "$out"
  fi
  losetup -d "$dos_dev" 2>/dev/null || true

  # 10. --verify reads the deployed drive against the recipe and says satisfied, writing nothing.
  out=$(cd "$repo" && ./terraform.sh --recipe "$work/owned.json" --disk "$owned_dev" --verify 2>&1)
  rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'recipe satisfied'; then
    pass=$((pass + 1))
    printf 'PASS --verify on the owned drive: %s\n' "$(printf '%s' "$out" | grep 'recipe satisfied')"
  else
    fail=$((fail + 1))
    printf 'FAIL --verify on the owned drive (exit %s)\n%s\n' "$rc" "$out"
  fi

  # 11. Appending into free space on a REAL drive. The fixture tier stubs sfdisk --append because a
  #     file has no kernel; only a loop device shows whether the appended partition actually appears,
  #     and whether the entries that already existed survive the append untouched.
  ap="$work/append.img"
  truncate -s 256M "$ap"
  ap_dev=$(losetup -f --partscan --show "$ap")
  mkdir -p "$work/mnt-append"
  sfdisk --label=gpt "$ap_dev" >/dev/null 2>&1 <<EOF
size=16M,type=$ESP_TYPE,name="EFI System Partition"
size=32M,type=$LINUX_TYPE,name="Linux filesystem"
EOF
  mkfs.vfat -F 32 "$ap_dev"p1 >/dev/null 2>&1
  ap_before=$(sfdisk --json "$ap_dev" | jq -c '.partitiontable.partitions')
  cat >"$work/append.json" <<EOF
{"owns": false, "partitions": [
  {"name": "boot", "fs": "vfat", "size": "16M", "mount": "/boot"},
  {"name": "nixos", "label": "nixos", "fs": "ext4", "size": "64M", "mount": "/"}
]}
EOF
  out=$(cd "$repo" && ./terraform.sh --recipe "$work/append.json" --disk "$ap_dev" --mount "$work/mnt-append" --force 2>&1)
  rc=$?
  [ -b "$ap_dev"p3 ] || losetup -R "$ap_dev" 2>/dev/null || true
  ap_after=$(sfdisk --json "$ap_dev" 2>/dev/null | jq -c '.partitiontable.partitions')
  ap_fs=$(blkid -o value -s TYPE "$ap_dev"p3 2>/dev/null || true)
  ap_label=$(blkid -o value -s LABEL "$ap_dev"p3 2>/dev/null || true)
  ap_src=$(findmnt -n -o SOURCE "$work/mnt-append" 2>/dev/null || true)
  if [ "$rc" = 0 ] && [ "$(printf '%s' "$ap_after" | jq 'length')" = 3 ] &&
    [ "$(printf '%s' "$ap_after" | jq -c '.[:2]')" = "$ap_before" ] &&
    [ "$ap_fs" = ext4 ] && [ "$ap_label" = nixos ] && [ "$ap_src" = "$ap_dev"p3 ]; then
    pass=$((pass + 1))
    printf 'PASS append into free space creates a real partition: 3 entries, first two unchanged, %s (ext4, label %s) mounted from %s\n' \
      "$ap_dev"p3 "$ap_label" "$ap_src"
  else
    fail=$((fail + 1))
    printf 'FAIL append on a real drive (exit %s, entries %s, p3 %s/%s, mount %s)\n%s\n' \
      "$rc" "$(printf '%s' "$ap_after" | jq 'length')" "$ap_fs" "$ap_label" "$ap_src" "$out"
  fi
  losetup -d "$ap_dev" 2>/dev/null || true

  printf 'summary: %d passed, %d failed, %d pending\n' "$pass" "$fail" "$pending"
}

main >"$log" 2>&1
rc=$?
printf 'log: %s (exit %d)\n' "$log" "$rc"
grep -E '^(PASS|FAIL|PENDING|summary)' "$log"
