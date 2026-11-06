#!/usr/bin/env bats
# terraform.sh against real bytes on disk fixtures (ADR-b77ec913151f).
#
# Nothing here builds a derivation and nothing here partitions a drive: the fixtures are sparse
# images whose partitions are real filesystems in files, so blkid, mkfs, mtools and debugfs all run
# for real. Only mount and findmnt are stubbed (they need root), and every tool that could rewrite a
# partition entry is stubbed to fail, so a partition write lands on the call log rather than being
# tolerated. A run costs milliseconds; the 15GB VM it replaces could not prove this anyway, because
# installTest renumbers devices to /dev/vda and never shows a partition another OS owns.
load helpers
load disk-fixture

setup() {
  harness_stub_dir
  fixture_dir

  stub mount <<EOF
#!/usr/bin/env bash
echo "mount \$*" >> "$calls"
mkdir -p "\${2:-/mnt}"
exit \${MOUNT_EXIT:-0}
EOF

  # findmnt models "already mounted" only after a mount was issued, which is what makes the
  # idempotent rerun a real second run rather than a canned answer.
  stub findmnt <<EOF
#!/usr/bin/env bash
echo "findmnt \$*" >> "$calls"
if [ "\$(cat "$stubs/mounted" 2>/dev/null)" = 1 ] || grep -q '^mount ' "$calls"; then echo /dev/vda2; exit 0; fi
exit 1
EOF

  # The ADR forbids these outright: a partition this flake does not own is never a target.
  for tool in sgdisk wipefs parted fdisk; do
    stub "$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit 1
EOF
  done

  printf '0\n' >"$stubs/mounted"
}

teardown() {
  fixture_teardown
  harness_teardown
}

# Nothing here is a stub of mkfs: real formatting is the point, so "nothing was formatted" is proven
# by a partition that still carries no signature (or still carries the one it had), not by a call log.
# mount is stubbed, so the mount assertions below do read a real log.
@test "a drive with no partition table is refused, and nothing is formatted" {
  mk_disk bare
  run terraform_run bare
  [ "$status" -eq 2 ]
  assert_out "no partition table"
  assert_no_call "mount "
}

@test "a blank ESP and a blank root, both declared by label, are formatted once" {
  mk_disk blank
  partition blank 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition blank 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  before=$(table_checksum blank)
  run terraform_run blank
  [ "$status" -eq 0 ]
  [ "$(type_of blank 1)" = vfat ]
  [ "$(label_of blank 1)" = boot ]
  [ "$(type_of blank 2)" = ext4 ]
  [ "$(label_of blank 2)" = nixos ]
  [ "$(table_checksum blank)" = "$before" ]
  assert_call "^mount .* $disk_dir/mnt$"
}

@test "a blank target the host names by UUID is refused, because mkfs invents a UUID the config cannot know" {
  mk_disk uuid
  partition uuid 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition uuid 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  TF_ROOT_DEV=/dev/disk/by-uuid/1234567890 run terraform_run uuid
  [ "$status" -eq 2 ]
  assert_out "UUID"
  [ "$(type_of uuid 1)" = "" ]
  [ "$(type_of uuid 2)" = "" ]
}

@test "an ESP that holds something other than vfat is refused, not reformatted" {
  mk_disk badesp
  partition badesp 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition badesp 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  format_slice badesp 1 "$ESP_START" "$ESP_N" ext4
  before=$(table_checksum badesp)
  run terraform_run badesp
  [ "$status" -eq 2 ]
  assert_out "not vfat"
  [ "$(table_checksum badesp)" = "$before" ]
  [ "$(type_of badesp 1)" = ext4 ]
}

@test "a Windows disk with no Linux partition is refused and left byte-identical" {
  mk_disk win
  partition win 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition win 2 "$MSR_START" "$MSR_END" "$MSR_TYPE" msr
  partition win 3 "$NTFS_START" "$NTFS_END" "$NTFS_TYPE" basic-data
  esp_foreign win Microsoft/BOOT
  seed_region win "$MSR_START" "$MSR_N" M
  seed_region win "$NTFS_START" "$NTFS_N" W
  esp_before=$(region_checksum win "$ESP_START" "$ESP_N")
  msr_before=$(region_checksum win "$MSR_START" "$MSR_N")
  ntfs_before=$(region_checksum win "$NTFS_START" "$NTFS_N")
  before=$(table_checksum win)
  run terraform_run win
  [ "$status" -eq 2 ]
  assert_out "holds ext4"
  [ "$(table_checksum win)" = "$before" ]
  [ "$(region_checksum win "$ESP_START" "$ESP_N")" = "$esp_before" ]
  [ "$(region_checksum win "$MSR_START" "$MSR_N")" = "$msr_before" ]
  [ "$(region_checksum win "$NTFS_START" "$NTFS_N")" = "$ntfs_before" ]
  [ "$(type_of win 1)" = vfat ]
  assert_no_call "mount "
}

@test "a Windows disk adopts the ESP and formats only the blank Linux partition" {
  mk_disk winblank
  partition winblank 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition winblank 2 "$MSR_START" "$MSR_END" "$MSR_TYPE" msr
  partition winblank 3 "$NTFS_START" "$NTFS_END" "$NTFS_TYPE" basic-data
  partition winblank 4 "$WIN_LINUX_START" "$WIN_LINUX_END" "$LINUX_TYPE" linux
  esp_foreign winblank Microsoft/BOOT
  seed_region winblank "$MSR_START" "$MSR_N" M
  seed_region winblank "$NTFS_START" "$NTFS_N" W
  esp_before=$(region_checksum winblank "$ESP_START" "$ESP_N")
  msr_before=$(region_checksum winblank "$MSR_START" "$MSR_N")
  ntfs_before=$(region_checksum winblank "$NTFS_START" "$NTFS_N")
  before=$(table_checksum winblank)

  run terraform_run winblank
  [ "$status" -eq 0 ]
  # Windows boot metadata is still there, and the regions it lives in did not move by a byte.
  mcopy -i "$disk_dir/winblank.img1" ::/EFI/Microsoft/BOOT/boot.efi "$disk_dir/winboot.efi"
  cmp "$disk_dir/loader.efi" "$disk_dir/winboot.efi"
  [ "$(region_checksum winblank "$ESP_START" "$ESP_N")" = "$esp_before" ]
  [ "$(region_checksum winblank "$MSR_START" "$MSR_N")" = "$msr_before" ]
  [ "$(region_checksum winblank "$NTFS_START" "$NTFS_N")" = "$ntfs_before" ]
  [ "$(table_checksum winblank)" = "$before" ]
  # Only partition 4 was written, and it is now the filesystem the host declared; the ESP still
  # holds the volume it came with, label and all.
  [ "$(type_of winblank 4)" = ext4 ]
  [ "$(label_of winblank 4)" = nixos ]
  assert_no_call "sgdisk"
  assert_no_call "wipefs"
  assert_no_call "parted"
}

@test "a Linux disk shared with another install adopts both partitions and writes nothing" {
  mk_disk lin
  partition lin 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition lin 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  esp_foreign lin systemd
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 otherlinux
  nodes lin
  root_data lin
  adopt lin 2 "$LINUX_START" "$LINUX_N"
  esp_before=$(region_checksum lin "$ESP_START" "$ESP_N")
  root_before=$(region_checksum lin "$LINUX_START" "$LINUX_N")
  before=$(table_checksum lin)

  run terraform_run lin
  [ "$status" -eq 0 ]
  # The other distro's loader survives in the ESP, and its root data survives too.
  mcopy -i "$disk_dir/lin.img1" ::/EFI/systemd/boot.efi "$disk_dir/foreign.efi"
  cmp "$disk_dir/loader.efi" "$disk_dir/foreign.efi"
  debugfs -R "dump /keep.txt $disk_dir/readback.txt" "$disk_dir/lin.img2" >/dev/null 2>&1
  cmp "$disk_dir/keep.txt" "$disk_dir/readback.txt"
  [ "$(region_checksum lin "$ESP_START" "$ESP_N")" = "$esp_before" ]
  [ "$(region_checksum lin "$LINUX_START" "$LINUX_N")" = "$root_before" ]
  [ "$(table_checksum lin)" = "$before" ]
  assert_call "^mount .* $disk_dir/mnt$"
}

@test "two Linux filesystems on one drive: the partition the host's mount names wins" {
  mk_disk pick
  partition pick 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition pick 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" foreign-root
  partition pick 3 "$LINUX2_START" "$LINUX2_END" "$LINUX_TYPE" nixos-root
  format_slice pick 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice pick 2 "$LINUX_START" "$LINUX_N" ext4 foreign
  format_slice pick 3 "$LINUX2_START" "$LINUX2_N" ext4 ours
  nodes pick
  root_data pick
  adopt pick 2 "$LINUX_START" "$LINUX_N"
  foreign_before=$(region_checksum pick "$LINUX_START" "$LINUX_N")

  # The host's mount names partition 3 by device; picking the first ext4 it sees would install over
  # the other install's root.
  TF_ROOT_DEV="$disk_dir/pick.img3" run terraform_run pick
  [ "$status" -eq 0 ]
  assert_call "^mount .* $disk_dir/mnt$"
  debugfs -R "dump /keep.txt $disk_dir/readback.txt" "$disk_dir/pick.img2" >/dev/null 2>&1
  cmp "$disk_dir/keep.txt" "$disk_dir/readback.txt"
  [ "$(region_checksum pick "$LINUX_START" "$LINUX_N")" = "$foreign_before" ]
  # Partition 3 is adopted, not reformatted: its own label survives.
  [ "$(label_of pick 3)" = ours ]
}

@test "a root partition whose filesystem is not the one the host declared is refused" {
  mk_disk mismatch
  partition mismatch 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition mismatch 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  format_slice mismatch 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice mismatch 2 "$LINUX_START" "$LINUX_N" ext4
  before=$(table_checksum mismatch)
  TF_ROOT_FS=btrfs run terraform_run mismatch
  [ "$status" -eq 2 ]
  assert_out "ext4"
  [ "$(type_of mismatch 2)" = ext4 ]
  [ "$(table_checksum mismatch)" = "$before" ]
}

@test "a second run adopts what the first made and issues no mount or mkfs" {
  mk_disk again
  partition again 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition again 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  run terraform_run again
  [ "$status" -eq 0 ]
  sync again
  before=$(table_checksum again)
  : >"$calls"
  printf '1\n' >"$stubs/mounted"
  run terraform_run again
  [ "$status" -eq 0 ]
  assert_no_call "mount "
  [ "$(table_checksum again)" = "$before" ]
  [ "$(type_of again 1)" = vfat ]
  [ "$(type_of again 2)" = ext4 ]
}
@test "a run that cannot read the table refuses instead of guessing" {
  stub jq <<EOF
#!/usr/bin/env bash
echo "jq \$*" >> "$calls"
exit 1
EOF
  mk_disk nojq
  partition nojq 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition nojq 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  run terraform_run nojq
  [ "$status" -eq 2 ]
  assert_out "partition table"
  [ "$(type_of nojq 1)" = "" ]
}

@test "a destructive step is refused when there is nobody to ask" {
  mk_disk prompt
  partition prompt 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition prompt 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  TF_FORCE=0 run terraform_run prompt
  [ "$status" -eq 2 ]
  assert_out "needs a confirmation and there is no terminal"
  [ "$(type_of prompt 1)" = "" ]
  [ "$(type_of prompt 2)" = "" ]
}

@test "--dry-run names the formats it would do and does none of them" {
  mk_disk dry
  partition dry 1 "$ESP_START" "$ESP_END" "$FAT32_TYPE" esp
  partition dry 2 "$LINUX_START" "$LINUX_END" "$LINUX_TYPE" root
  run terraform_run dry --dry-run
  assert_out "[dry-run] mkfs.vfat"
  assert_out "[dry-run] mkfs.ext4"
  [ "$(type_of dry 1)" = "" ]
  [ "$(type_of dry 2)" = "" ]
}
