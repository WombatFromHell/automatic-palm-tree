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

setup_file() { fixture_setup_file; }
teardown_file() { fixture_teardown_file; }

setup() {
  harness_stub_dir
  fixture_dir

  stub mount <<EOF
#!/usr/bin/env bash
echo "mount \$*" >> "$calls"
last=\$#
# The device is the second-to-last argument and the target is the last one, so this models
# \`mount <node> <dir>\` and \`mount -o subvol=@ <node> <dir>\` alike. Each mount is recorded against
# its own target, so findmnt below can answer per path rather than "something is mounted".
# Real mount refuses a target that is not a directory; the run is expected to create it.
if [ ! -d "\${@:last:1}" ]; then
  echo "mount: \${@:last:1}: mount point does not exist" >&2
  exit 32
fi
printf '%s %s\n' "\${@:last:1}" "\${@:last-1:1}" >> "$stubs/mounts"
exit \${MOUNT_EXIT:-0}
EOF

  # umount is stubbed like mount: it needs root, and the run only ever unmounts what it mounted.
  stub umount <<EOF
#!/usr/bin/env bash
echo "umount \$*" >> "$calls"
exit \${UMOUNT_EXIT:-0}
EOF

  # btrfs subvolume needs a mounted btrfs filesystem, which a fixture has none of. It models the
  # guard create_subvolumes runs on: a name already created answers \`show\`, a new one does not.
  stub btrfs <<EOF
#!/usr/bin/env bash
echo "btrfs \$*" >> "$calls"
if [ "\$1" = subvolume ] && [ "\$2" = show ]; then
  grep -qxF "\${3##*/}" "$stubs/subvols" 2>/dev/null && exit 0
  exit 1
fi
if [ "\$1" = subvolume ] && [ "\$2" = create ]; then
  printf '%s\n' "\${3##*/}" >> "$stubs/subvols"
  exit 0
fi
exit 0
EOF

  # findmnt models "already mounted" only after a mount was issued, which is what makes the
  # idempotent rerun a real second run rather than a canned answer. The source it reports is the
  # device the run mounted, so verify_mount can be checked against it rather than trusted.
  stub findmnt <<EOF
#!/usr/bin/env bash
echo "findmnt \$*" >> "$calls"
path="\${@:\$#}"
src="\$(grep -m1 "^\$path " "$stubs/mounts" 2>/dev/null | cut -d' ' -f2)"
if [ -n "\$src" ]; then echo "\$src"; exit 0; fi
if [ "\$(cat "$stubs/mounted" 2>/dev/null)" = 1 ]; then echo "\${MOUNTED_SRC:-/dev/vda2}"; exit 0; fi
exit 1
EOF

  # No candidates by default, so a recipe run can never reach this machine's real disks.
  stub_lsblk

  # sfdisk is the real binary — a fixture image holds a real GPT — except --append: on a real drive
  # that call is answered by the kernel creating a partition node, and a file has no kernel. The
  # slice is cut here exactly as nodes() cuts the others, so a run can format what it just created.
  sfdisk_real=$(command -v sfdisk)
  stub sfdisk <<EOF
#!/usr/bin/env bash
echo "sfdisk \$*" >> "$calls"
# --force is the overwrite answer the shipped script passes when the drive already holds a table.
# Stripped here so the branches below still dispatch on the layout they were written for.
if [ "\$1" = --force ]; then shift; fi
if [ "\$1" = --append ]; then
  cat > "$stubs/append.txt"
  # The layout arrives on stdin, the way terraform.sh feeds it; naming the file would make
  # sfdisk read it as a partition number.
  "$sfdisk_real" --append "\$2" <"$stubs/append.txt" || exit 2
  idx=\$("$sfdisk_real" --json "\$2" | jq -r '.partitiontable.partitions | length')
  read -r start size < <("$sfdisk_real" --json "\$2" | jq -r ".partitiontable.partitions[\$((idx - 1))] | \"\(.start) \(.size)\"")
  dd if="\$2" of="\$2\$idx" bs=512 "skip=\$start" "count=\$size" status=none
  exit 0
fi
if [ "\$1" = -X ] && [ "\$2" = gpt ]; then
  # Owned mode writes the whole table, and a real disk gets partition nodes from the kernel while a
  # file gets none. The slices are cut here, exactly as nodes() cuts the others, so mkfs has
  # something to format and blkid something to read.
  cat > "$stubs/layout.txt"
  "$sfdisk_real" -X gpt "\$3" <"$stubs/layout.txt" || exit 2
  "$sfdisk_real" --json "\$3" | jq -r '.partitiontable.partitions[] | "\(.node) \(.start) \(.size)"' |
    while read -r node start size; do
      dd if="\$3" of="\$node" bs=512 "skip=\$start" "count=\$size" status=none
    done
  exit 0
fi
exec "$sfdisk_real" "\$@"
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
  : >"$stubs/mounts"
}

teardown() {
  fixture_teardown
  harness_teardown
}

# Nothing here is a stub of mkfs: real formatting is the point, so "nothing was formatted" is proven
# by a partition that still carries no signature (or still carries the one it had), not by a call log.
# mount is stubbed, so the mount assertions below do read a real log.
@test "a drive with no partition table is refused, and nothing is formatted" {
  disk bare
  run terraform_run bare
  [ "$status" -eq 2 ]
  assert_out "no partition table"
  assert_no_call "mount "
}

# The installer mounts the root itself, and mount refuses a target that is a non-directory. A
# minimal install medium (tmpfs root) has no /mnt at all, so terraform.sh creates the mount root the
# way mount_extra creates its siblings. mkdir is not stubbed, so the proof is the directory itself:
# the mount stub refuses a target that is not a directory, so a green run can only mean it was made.
@test "the mount root is created when the target directory does not exist" {
  truncate -s 128M "$disk_dir/own.img"
  stub_lsblk "$disk_dir/own.img"
  recipe_file "$stubs/owned.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"
  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  [ -d "$disk_dir/mnt" ]
  assert_call "^mount $disk_dir/own.img2 $disk_dir/mnt$"
}

@test "a blank ESP and a blank root, both declared by label, are formatted once" {
  disk blank
  snapshot blank
  run terraform_run blank
  [ "$status" -eq 0 ]
  [ "$(type_of blank 1)" = vfat ]
  [ "$(label_of blank 1)" = boot ]
  [ "$(type_of blank 2)" = ext4 ]
  [ "$(label_of blank 2)" = nixos ]
  assert_unchanged blank
  assert_call "^mount .* $disk_dir/mnt$"
}

@test "a blank target the host names by UUID is refused, because mkfs invents a UUID the config cannot know" {
  disk uuid blank
  TF_ROOT_DEV=/dev/disk/by-uuid/1234567890 run terraform_run uuid
  [ "$status" -eq 2 ]
  assert_out "UUID"
  [ "$(type_of uuid 1)" = "" ]
  [ "$(type_of uuid 2)" = "" ]
}

@test "an ESP that holds something other than vfat is refused, not reformatted" {
  disk badesp blank
  format_slice badesp 1 "$ESP_START" "$ESP_N" ext4
  snapshot badesp
  run terraform_run badesp
  [ "$status" -eq 2 ]
  assert_out "not vfat"
  assert_unchanged badesp
  [ "$(type_of badesp 1)" = ext4 ]
}

@test "a Windows disk with no Linux partition is refused and left byte-identical" {
  image win win Microsoft/BOOT
  snapshot win
  run terraform_run win
  [ "$status" -eq 2 ]
  assert_out "holds ext4"
  assert_unchanged win
  [ "$(type_of win 1)" = vfat ]
  assert_no_call "mount "
}

@test "a Windows disk adopts the ESP and formats only the blank Linux partition" {
  image winblank winblank Microsoft/BOOT
  snapshot winblank

  run terraform_run winblank
  [ "$status" -eq 0 ]
  # Windows boot metadata is still there, and the regions it lives in did not move by a byte.
  mcopy -i "$disk_dir/winblank.img1" ::/EFI/Microsoft/BOOT/boot.efi "$disk_dir/winboot.efi"
  cmp "$disk_dir/loader.efi" "$disk_dir/winboot.efi"
  assert_unchanged winblank
  # Only partition 4 was written, and it is now the filesystem the host declared; the ESP still
  # holds the volume it came with, label and all.
  [ "$(type_of winblank 4)" = ext4 ]
  [ "$(label_of winblank 4)" = nixos ]
  assert_no_call "sgdisk"
  assert_no_call "wipefs"
  assert_no_call "parted"
}

# An ESP is a partition type, not just a filesystem: firmware scans the ESP GUID (UEFI 2.7 §12.3), so
# a partition terraform.sh creates must carry it. The FAT32 GUID is a data volume, and a drive whose
# ESP was created by firmware or another installer carries the ESP GUID under some other GPT name.
@test "a created ESP carries the ESP partition type, not the FAT32 type" {
  owned own bare
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  [ "$(entries_json own | jq -r '.[0].type')" = "$ESP_TYPE" ]
  [ "$(type_of own 1)" = vfat ]
  [ "$(label_of own 1)" = boot ]
}

@test "a blank ESP partition typed as an ESP is adopted, whatever its GPT name says" {
  owned espghost
  before=$(entries_json espghost)
  recipe_file "$disk_dir/r.json" false 'esp:boot:vfat:8M:/boot,root:nixos:ext4:rest:/'
  run terraform_recipe_run espghost "$disk_dir/r.json"
  [ "$status" -eq 0 ]
  # The ESP that already existed is the one that got formatted: a second ESP would be two devices
  # answering to one /boot, and the entry that existed must come back identical.
  [ "$(printf '%s\n' "$before" | jq -c '.[0]')" = "$(entries_json espghost | jq -c '.[0]')" ]
  [ "$(entries_json espghost | jq 'length')" = 2 ]
  [ "$(type_of espghost 1)" = vfat ]
  [ "$(label_of espghost 1)" = boot ]
}

@test "a shared-mode dry run plans the partition it would append and writes nothing" {
  # The ESP here is the one this host owns (labelled boot, adopted); the root has nowhere to live, so
  # the plan is a creation. A dry run has to show that plan and leave every byte alone.
  owned tight
  format_slice tight 1 "$ESP_START" "$ESP_N" vfat boot
  seed_region tight "$NTFS_START" "$NTFS_N" W
  snapshot tight "$NTFS_START" "$NTFS_N"
  entries_before=$(entries_json tight)
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:rest:/"
  run terraform_recipe_run tight "$stubs/recipe.json" --dry-run
  [ "$status" -eq 0 ]
  assert_out "esp: adopt"
  assert_out "root: create rest"
  assert_unchanged tight
  [ "$(entries_json tight)" = "$entries_before" ]
  assert_no_call "mkfs"
  assert_no_call "mount "
}

@test "a Linux disk shared with another install adopts both partitions and writes nothing" {
  disk lin blank
  esp_foreign lin systemd
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 otherlinux
  nodes lin
  root_data lin
  adopt lin 2 "$LINUX_START" "$LINUX_N"
  snapshot lin "$ESP_START" "$ESP_N" "$LINUX_START" "$LINUX_N"

  run terraform_run lin
  [ "$status" -eq 0 ]
  # The other distro's loader survives in the ESP, and its root data survives too.
  mcopy -i "$disk_dir/lin.img1" ::/EFI/systemd/boot.efi "$disk_dir/foreign.efi"
  cmp "$disk_dir/loader.efi" "$disk_dir/foreign.efi"
  debugfs -R "dump /keep.txt $disk_dir/readback.txt" "$disk_dir/lin.img2" >/dev/null 2>&1
  cmp "$disk_dir/keep.txt" "$disk_dir/readback.txt"
  assert_unchanged lin
  assert_call "^mount .* $disk_dir/mnt$"
}

@test "two Linux filesystems on one drive: the partition the host's mount names wins" {
  disk pick
  format_slice pick 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice pick 2 "$LINUX_START" "$LINUX_N" ext4 foreign
  format_slice pick 3 "$LINUX2_START" "$LINUX2_N" ext4 ours
  nodes pick
  root_data pick
  adopt pick 2 "$LINUX_START" "$LINUX_N"
  snapshot_regions pick "$LINUX_START" "$LINUX_N"

  # The host's mount names partition 3 by device; picking the first ext4 it sees would install over
  # the other install's root.
  TF_ROOT_DEV="$disk_dir/pick.img3" run terraform_run pick
  [ "$status" -eq 0 ]
  assert_call "^mount .* $disk_dir/mnt$"
  debugfs -R "dump /keep.txt $disk_dir/readback.txt" "$disk_dir/pick.img2" >/dev/null 2>&1
  cmp "$disk_dir/keep.txt" "$disk_dir/readback.txt"
  assert_unchanged pick
  # Partition 3 is adopted, not reformatted: its own label survives.
  [ "$(label_of pick 3)" = ours ]
}

@test "a root partition whose filesystem is not the one the host declared is refused" {
  disk mismatch blank
  format_slice mismatch 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice mismatch 2 "$LINUX_START" "$LINUX_N" ext4
  snapshot mismatch
  TF_ROOT_FS=btrfs run terraform_run mismatch
  [ "$status" -eq 2 ]
  assert_out "ext4"
  [ "$(type_of mismatch 2)" = ext4 ]
  assert_unchanged mismatch
}

@test "a second run adopts what the first made and issues no mount or mkfs" {
  disk again blank
  run terraform_run again
  [ "$status" -eq 0 ]
  sync again
  snapshot again
  : >"$calls"
  printf '1\n' >"$stubs/mounted"
  run terraform_run again
  [ "$status" -eq 0 ]
  assert_no_call "mount "
  assert_unchanged again
  [ "$(type_of again 1)" = vfat ]
  [ "$(type_of again 2)" = ext4 ]
}
@test "a run that cannot read the table refuses instead of guessing" {
  stub jq <<EOF
#!/usr/bin/env bash
echo "jq \$*" >> "$calls"
exit 1
EOF
  disk nojq blank
  run terraform_run nojq
  [ "$status" -eq 2 ]
  assert_out "partition table"
  [ "$(type_of nojq 1)" = "" ]
}

@test "a destructive step is refused when there is nobody to ask" {
  disk prompt blank
  TF_FORCE=0 run terraform_run prompt
  [ "$status" -eq 2 ]
  assert_out "needs a confirmation and there is no terminal"
  [ "$(type_of prompt 1)" = "" ]
  [ "$(type_of prompt 2)" = "" ]
}

@test "--dry-run names the formats it would do and does none of them" {
  disk dry blank
  run terraform_run dry --dry-run
  assert_out "[dry-run] mkfs.vfat"
  assert_out "[dry-run] mkfs.ext4"
  [ "$(type_of dry 1)" = "" ]
  [ "$(type_of dry 2)" = "" ]
}

@test "a recipe drives the whole run, and discovery finds the drive from its own fingerprints" {
  owned blank
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  run terraform_recipe_run blank "$stubs/recipe.json"
  [ "$status" -eq 0 ]
  [ "$(type_of blank 1)" = vfat ]
  [ "$(label_of blank 1)" = boot ]
  [ "$(type_of blank 2)" = ext4 ]
  [ "$(label_of blank 2)" = nixos ]
  assert_call "^mount .* $disk_dir/mnt$"
}

@test "discovery refuses when two drives carry the recipe's fingerprints" {
  disk blank
  disk twin blank
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  stub_lsblk "$disk_dir/blank.img" "$disk_dir/twin.img"
  snapshot twin
  run terraform_recipe_run blank "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "two drives match"
  [ "$(type_of blank 1)" = "" ]
  [ "$(type_of twin 1)" = "" ]
  assert_unchanged twin
  assert_no_call "mount "
}

@test "discovery refuses a drive whose table holds none of the recipe's fingerprints" {
  image win win Microsoft/BOOT
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  run terraform_recipe_run win "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "no drive matches"
  assert_unchanged win
  assert_no_call "mount "
}

@test "--disk is the operator override, so discovery does not run" {
  disk blank
  run terraform_run blank
  [ "$status" -eq 0 ]
  assert_no_call "lsblk"
}

@test "a recipe the reader does not understand is refused before anything is written" {
  owned blank

  recipe_file "$stubs/badfs.json" false "esp:boot:vfat:8M:/boot,root:nixos:reiserfs:16M:/"
  run terraform_recipe_run blank "$stubs/badfs.json"
  [ "$status" -eq 2 ]
  assert_out "reiserfs"
  [ "$(type_of blank 1)" = "" ]

  # xfs is a filesystem format_blank can make, so it is accepted. The near miss is an xfs option on a
  # partition that is not xfs, which mount would take as a parameter that filesystem does not have.
  recipe_file "$stubs/xfs.json" false "esp:boot:vfat:8M:/boot,root:nixos:xfs:16M:/"
  run terraform_recipe_run blank "$stubs/xfs.json" --dry-run
  [ "$status" -eq 0 ]
  assert_out "[dry-run] mkfs.xfs"
  [ "$(type_of blank 1)" = "" ]

  recipe_file "$stubs/noxfs.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/:logbsize=256k"
  run terraform_recipe_run blank "$stubs/noxfs.json"
  [ "$status" -eq 2 ]
  assert_out "non-xfs partition with xfs options"
  [ "$(type_of blank 1)" = "" ]

  recipe_file "$stubs/tworoots.json" false "root:nixos:ext4:16M:/,other:alt:ext4:16M:/"
  run terraform_recipe_run blank "$stubs/tworoots.json"
  [ "$status" -eq 2 ]
  assert_out "mounting /"
  [ "$(type_of blank 1)" = "" ]
}

# R2 — free-space maths. A declared size that no existing partition covers has to fit the
# 1MiB-aligned gaps the table leaves, and that has to be settled before a single write. On this
# fixture the gaps are 8M (between ESP and root) and 34M (after root); the last 1MiB of the drive is
# the backup partition table, so it is never free space.
@test "a recipe needing more than the free gaps fails before anything is formatted" {
  owned spare blank
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/,data:data:ext4:36M:/data"
  snapshot spare

  run terraform_recipe_run spare "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "data needs 36M"
  assert_out "free"
  [ "$(type_of spare 1)" = "" ]
  [ "$(type_of spare 2)" = "" ]
  assert_no_call "sgdisk"
  assert_no_call "wipefs"
  assert_no_call "mount "
  assert_unchanged spare
}

@test "the gap boundary is exact: 34M fits, 35M does not" {
  # Two copies of the same shape: the first run appends, so the second must not see its work.
  disk fits blank
  disk nofits blank
  snapshot nofits

  stub_lsblk "$disk_dir/fits.img"
  recipe_file "$stubs/fits.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/,data:data:ext4:34M:/data"
  run terraform_recipe_run fits "$stubs/fits.json"
  assert_out "data: create 34M"

  stub_lsblk "$disk_dir/nofits.img"
  recipe_file "$stubs/no.fits.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/,data:data:ext4:35M:/data"
  run terraform_recipe_run nofits "$stubs/no.fits.json"
  [ "$status" = 2 ]
  assert_out "data needs 35M"
  [ "$(type_of nofits 1)" = "" ]
  assert_unchanged nofits
}

@test "an entry that fits a free gap is planned as create, and nothing is written without a yes" {
  owned spare blank
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/,data:data:ext4:8M:/data"
  snapshot spare

  TF_FORCE=0 run terraform_recipe_run spare "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "data: create 8M"
  assert_out "needs a confirmation and there is no terminal"
  assert_unchanged spare
  assert_no_call "mkfs"
}

@test "rest with no free space left refuses rather than sizing nothing" {
  owned full
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/,data:data:ext4:rest:/data"
  snapshot full

  run terraform_recipe_run full "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "data declares rest"
  assert_out "no free space"
  assert_unchanged full
  assert_no_call "mount "
}

@test "a size the reader cannot turn into bytes is refused before any write" {
  owned spare blank
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/,data:data:ext4:12Q:/data"
  snapshot spare

  run terraform_recipe_run spare "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "12Q"
  assert_unchanged spare
  assert_no_call "mkfs"
}

# R3/R5 — owned mode. The fixture tier proves the decisions that keep a drive safe: what refuses,
# what is planned, and what a re-read reports. The geometry itself (a real GPT written, real
# partition nodes, real mkfs) is proven on loop devices by tests/deploy-loop.sh, because sfdisk will
# not create a partition table on a regular file and mkfs.btrfs refuses one.
@test "owns=true refuses a drive holding a filesystem the recipe does not claim" {
  owned own blank
  format_slice own 2 "$LINUX_START" "$LINUX_N" ext4 other
  adopt own 2 "$LINUX_START" "$LINUX_N"
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:btrfs:54M:/"
  TF_FORCE=0 run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 2 ]
  assert_out "ext4"
  [ "$(type_of own 2)" = ext4 ]
  assert_no_call "sfdisk -X gpt"
}

# --force is the operator's answer to the destructive prompt, so a drive that already holds somebody's
# partitions is wiped and the recipe's layout is laid over it. Without this the deploy contract could
# never run on a drive that had been installed on before: any partition holding a filesystem the recipe
# does not claim refused the run outright, --force included.
@test "owns=true --force wipes a drive whose partitions hold filesystems the recipe does not claim" {
  # A drive installed before: an ESP this recipe claims and a root holding ext4 it does not.
  # mkfs.btrfs refuses below ~114MB, so the root is `rest` on a 128M drive.
  owned own pre-ext4
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:btrfs:114M:/"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --force
  [ "$status" -eq 0 ]
  assert_out "ext4"
  assert_out "fresh GPT partition table"
  [ "$(type_of own 2)" = btrfs ]
  [ "$(label_of own 2)" = nixos ]
}

# The geometry may already match while a partition holds the wrong filesystem: the table is adopted,
# and the partition owns=true claims is formatted to what the recipe declares.
@test "owns=true formats an adopted partition holding the filesystem the recipe does not declare" {
  owned own pre-ext4
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:btrfs:rest:/"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --force
  [ "$status" -eq 0 ]
  [ "$(type_of own 1)" = vfat ]
  [ "$(type_of own 2)" = btrfs ]
  [ "$(label_of own 2)" = nixos ]
}

# R5: a drive with no partition table but raw filesystem bytes is somebody's data, not blank space.
@test "owns=true refuses a tableless drive whose raw bytes hold a filesystem" {
  owned raw
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  snapshot raw
  run terraform_recipe_run raw "$stubs/recipe.json" --disk "$disk_dir/raw.img"
  [ "$status" -eq 2 ]
  assert_out "ext4"
  assert_unchanged raw
}

@test "owns=true refuses to guess a drive: a wipe needs the drive named" {
  owned own bare
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  run terraform_recipe_run own "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "name"
}

@test "owns=true with nobody to confirm writes nothing at all" {
  owned own bare
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  snapshot own
  TF_FORCE=0 run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 2 ]
  assert_out "no terminal"
  assert_unchanged own
}

@test "owns=true --dry-run names the layout it would write and writes none of it" {
  owned own bare
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  snapshot own
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --dry-run
  [ "$status" -eq 0 ]
  assert_out "esp: create 8M"
  assert_out "root: create 54M"
  assert_out "[dry-run] sfdisk"
  assert_out "[dry-run] mkfs.vfat"
  assert_out "[dry-run] mkfs.ext4"
  assert_unchanged own
  [ "$(type_of own 1)" = "" ]
}

# Owned mode on a btrfs root has to lay down the subvolume tree the host's config mounts, or NixOS
# boots into a mount of a subvolume that was never created.
# deploy writes the boot loader into the config's efiSysMountPoint, and systemd-boot refuses a /boot
# that is not a mount. terraform.sh mounts every mount the recipe declares, not just the root, and a
# rerun adopts the mount it already made.
@test "owns=true mounts every mount the recipe declares, and a rerun adopts it" {
  truncate -s 128M "$disk_dir/own.img"
  stub_lsblk "$disk_dir/own.img"
  recipe_file "$stubs/owned.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"
  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  assert_call "^mount -o fmask=0077,dmask=0077 $disk_dir/own.img1 $disk_dir/mnt/boot$"
  nodes own
  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  assert_out "$disk_dir/mnt/boot already mounted — adopted, not rebuilt"
}

@test "owns=true on a btrfs root creates the subvolume tree and mounts @ as /" {
  # btrfs-progs refuses a filesystem below ~114MB and the ESP takes 9MB of the drive, so 128M is the
  # smallest drive that holds an ESP plus a btrfs root. Every owned-mode drive here is that size.
  truncate -s 128M "$disk_dir/own.img"
  stub_lsblk "$disk_dir/own.img"
  recipe_file "$stubs/owned.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"

  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  assert_out "nixos: create rest (btrfs)"
  assert_call "^btrfs subvolume create $disk_dir/mnt/@$"
  assert_call "^btrfs subvolume create $disk_dir/mnt/@nix$"
  assert_call "^btrfs subvolume create $disk_dir/mnt/@swap$"
  assert_call "^umount $disk_dir/mnt$"
  assert_call "^mount -o noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt$"
  assert_call "^mount -o subvol=@,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt$"
  [ "$(type_of own 2)" = btrfs ]
}

# Creating the tree is only half of it: every sibling of @ is a mount hosts/methyl-nixos/nixos.nix
# declares, and staging has to mount it. deploy writes the closure into @nix; if @nix is only
# created, the boot mount of an empty @nix over /nix hides that closure, stage 2's init is not in
# /nix/store, and the host lands in emergency.target. Same for @home, where postdeploy writes the
# ssh keys.
@test "owns=true mounts every subvolume of the tree where the installed system mounts it" {
  truncate -s 128M "$disk_dir/own.img"
  stub_lsblk "$disk_dir/own.img"
  recipe_file "$stubs/owned.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"
  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  assert_call "^mount -o subvol=@nix,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt/nix$"
  assert_call "^mount -o subvol=@home,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt/home$"
  assert_call "^mount -o subvol=@log,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt/var/log$"
  assert_call "^mount -o subvol=@cache,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt/var/cache$"
  assert_call "^mount -o subvol=@swap,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt/var/lib/swap$"
  assert_call "^mount -o subvol=@snapshots,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt/.snapshots$"
  # @ is the filesystem root's own mount: it is mounted once, at $mount, and never again as a sibling.
  assert_calls "^mount -o subvol=@,noatime,compress=zstd $disk_dir/own.img2 $disk_dir/mnt$" 1
}

# A rerun of the same recipe is the same staging mount set: a subvolume already mounted is adopted,
# not mounted twice, so a second --stage terraform changes nothing.
@test "a rerun adopts the subvolume mounts it already made" {
  truncate -s 128M "$disk_dir/own.img"
  stub_lsblk "$disk_dir/own.img"
  recipe_file "$stubs/owned.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"
  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  : >"$calls"
  printf '1\n' >"$stubs/mounted"
  MOUNTED_SRC="$disk_dir/own.img2" run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  assert_out "$disk_dir/mnt/nix already mounted — adopted, not rebuilt"
  assert_out "$disk_dir/mnt/home already mounted — adopted, not rebuilt"
  assert_no_call "mount -o subvol=@nix"
  assert_no_call "mount -o subvol=@home"
}

# A dry run writes nothing, and mounting is a write to this machine's mount table.
@test "owns=true --dry-run on a btrfs root creates and mounts no tree" {
  truncate -s 128M "$disk_dir/own.img"
  stub_lsblk "$disk_dir/own.img"
  recipe_file "$stubs/owned.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"
  snapshot own
  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img" --dry-run
  [ "$status" = 0 ]
  assert_no_call "btrfs subvolume create"
  assert_no_call "mount -o subvol=@"
  assert_no_call "umount"
  assert_unchanged own
}

# A second owned run is the same recipe on the same drive: the table it would write is already there,
# so nothing is written and the tree that already exists is adopted rather than recreated.
@test "a second owned run adopts the table it already wrote and creates nothing" {
  truncate -s 128M "$disk_dir/own.img"
  stub_lsblk "$disk_dir/own.img"
  recipe_file "$stubs/owned.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"
  run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  sync own
  snapshot own
  entries_before=$(entries_json own)
  : >"$calls"
  printf '1\n' >"$stubs/mounted"

  # findmnt has to report the root partition this run mounted, not a canned /dev/vda2.
  MOUNTED_SRC="$disk_dir/own.img2" run terraform_recipe_run own "$stubs/owned.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 0 ]
  assert_out "already holds the layout the recipe declares"
  assert_out "already mounted"
  assert_no_call "sfdisk -X gpt"
  assert_no_call "mkfs"
  assert_no_call "btrfs subvolume create"
  [ "$(entries_json own)" = "$entries_before" ]
  assert_unchanged own
}

# The tree is content of the root filesystem, not something a run only does when it formatted that
# filesystem: a drive that holds the layout but only @ would boot into mounts the config declares and
# that were never created.
@test "an adopted btrfs root that lacks the tree lays it down and mounts @ as /" {
  truncate -s 128M "$disk_dir/tree.img"
  stub_lsblk "$disk_dir/tree.img"
  recipe_file "$stubs/tree.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/"
  run terraform_recipe_run tree "$stubs/tree.json" --disk "$disk_dir/tree.img"
  [ "$status" -eq 0 ]
  printf '@\n' >"$stubs/subvols"
  : >"$calls"

  run terraform_recipe_run tree "$stubs/tree.json" --disk "$disk_dir/tree.img"
  [ "$status" -eq 0 ]
  assert_out "already holds the layout the recipe declares"
  assert_call "^btrfs subvolume create $disk_dir/mnt/@nix$"
  assert_call "^btrfs subvolume create $disk_dir/mnt/@swap$"
  assert_no_call "btrfs subvolume create $disk_dir/mnt/@$"
  assert_call "^mount -o subvol=@,noatime,compress=zstd $disk_dir/tree.img2 $disk_dir/mnt$"
  assert_no_call "mkfs"
}

# btrfs options on a partition that is not btrfs reach mount as a parameter that filesystem does not
# have, so they are refused at recipe read rather than passed on to fail.
@test "a recipe that mounts a non-btrfs partition with btrfs options is refused before any write" {
  owned own bare
  recipe_file "$stubs/mix.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/:compress=zstd"
  snapshot own
  run terraform_recipe_run own "$stubs/mix.json" --disk "$disk_dir/own.img"
  [ "$status" -eq 2 ]
  assert_out "non-btrfs partition with btrfs options"
  assert_unchanged own
}

# The options a btrfs root is mounted with are the ones hosts/methyl-nixos/nixos.nix declares, and an
# entry that declares its own wins over them.
@test "a recipe that declares mount options wins over the defaults" {
  truncate -s 128M "$disk_dir/opt.img"
  stub_lsblk "$disk_dir/opt.img"
  recipe_file "$stubs/opt.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/:nodatacow"

  run terraform_recipe_run opt "$stubs/opt.json" --disk "$disk_dir/opt.img"
  [ "$status" -eq 0 ]
  assert_call "^mount -o nodatacow $disk_dir/opt.img2 $disk_dir/mnt$"
  assert_call "^mount -o subvol=@,nodatacow $disk_dir/opt.img2 $disk_dir/mnt$"
}

# A shared drive is mounted by the same code path, so a btrfs root that already exists gets the same
# options rather than a bare mount.
@test "a shared btrfs root is mounted with the same options as an owned one" {
  owned bts pre-btrfs
  recipe_file "$stubs/bts.json" false "esp:boot:vfat:8M:/boot,root:nixos:btrfs:rest:/"

  run terraform_recipe_run bts "$stubs/bts.json" --disk "$disk_dir/bts.img"
  [ "$status" -eq 0 ]
  assert_call "^mount -o noatime,compress=zstd $disk_dir/bts.img2 $disk_dir/mnt$"
  assert_no_call "mkfs"
}

# The defaults are per filesystem, so a root that exists already gets its own and not btrfs's.
# mkfs.xfs refuses a device below 300MiB, so the xfs drive is the big one of the two.
@test "a root that exists already is mounted with its own filesystem's default options" {
  for fs in ext4 xfs; do
    # The formatted drives come from the fixture templates (disk-fixture.bash): this test asserts
    # mkfs is never called, so laying them down per test was pure setup cost.
    disk "$fs" "pre-$fs"
    stub_lsblk "$disk_dir/$fs.img"
    recipe_file "$stubs/$fs.json" false "esp:boot:vfat:8M:/boot,root:nixos:$fs:rest:/"
    : >"$calls"
    : >"$stubs/mounts" # the mounts the previous iteration made must not be seen by this one

    run terraform_recipe_run "$fs" "$stubs/$fs.json" --disk "$disk_dir/$fs.img"
    [ "$status" -eq 0 ]
    assert_no_call "mkfs"
    case "$fs" in
    ext4) assert_call "^mount -o noatime $disk_dir/ext4.img2 $disk_dir/mnt$" ;;
    xfs) assert_call "^mount -o noatime,logbsize=256k,noquota $disk_dir/xfs.img2 $disk_dir/mnt$" ;;
    esac
  done
}

# An entry that declares its options as empty is a decision, not a missing field: it asks for the
# kernel's defaults, so the per-filesystem fallback must not be added back.
@test "a recipe that declares empty mount options overrides the defaults" {
  truncate -s 128M "$disk_dir/none.img"
  stub_lsblk "$disk_dir/none.img"
  recipe_file "$stubs/none.json" true "boot:boot:vfat:8M:/boot,nixos:nixos:btrfs:rest:/:"

  run terraform_recipe_run none "$stubs/none.json" --disk "$disk_dir/none.img"
  [ "$status" -eq 0 ]
  assert_call "^mount $disk_dir/none.img2 $disk_dir/mnt$"
  assert_call "^mount -o subvol=@ $disk_dir/none.img2 $disk_dir/mnt$"
}

# Options that cannot survive a word boundary would reach mount as two arguments.
@test "mount options with a space in them refuse before any write" {
  owned blank blank
  recipe_file "$stubs/spaced.json" false "root:nixos:ext4:16M:/:noatime compress=zstd"
  snapshot blank

  run terraform_recipe_run blank "$stubs/spaced.json" --disk "$disk_dir/blank.img"
  [ "$status" -eq 2 ]
  assert_out "comma-separated"
  assert_no_call "mkfs"
  assert_no_call "mount "
  assert_unchanged blank
}

# A filesystem under the recipe's own label that is smaller than the recipe asks for cannot be
# adopted (resize is never attempted) and cannot be appended to, because two partitions answering to
# one label is two devices for one name. It refuses, and the drive is untouched.
@test "a partition holding the recipe's filesystem under its label but too small refuses before any write" {
  owned small blank
  format_slice small 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice small 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes small
  recipe_file "$stubs/big.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:32M:/"
  snapshot small

  run terraform_recipe_run small "$stubs/big.json"
  [ "$status" -eq 2 ]
  assert_out "resize is never attempted"
  assert_out "32M"
  assert_no_call "mkfs"
  assert_no_call "mount "
  assert_unchanged small
}

# A blank partition the entry does not fit is somebody else's space to leave alone: the entry goes
# into the free gap instead, and the partition that was too small keeps its bytes.
@test "a blank partition too small for an entry is left alone and the entry is appended into free space" {
  image gap winblank
  recipe_file "$stubs/gap.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:20M:/"
  before=$(entries_json gap)

  run terraform_recipe_run gap "$stubs/gap.json"
  [ "$status" -eq 0 ]
  assert_out "root: create 20M"
  assert_call "^sfdisk --append"
  [ "$(printf '%s\n' "$before" | jq 'length')" = 4 ]
  [ "$(printf '%s\n' "$(entries_json gap)" | jq 'length')" = 5 ]
  [ "$(printf '%s\n' "$(entries_json gap)" | jq -c '.[:4]')" = "$before" ]
  [ "$(type_of gap 5)" = ext4 ]
  [ "$(label_of gap 5)" = nixos ]
  assert_unchanged gap
}

@test "--verify reports what the drive holds against the recipe, read-only" {
  owned lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  snapshot lin

  run terraform_recipe_run lin "$stubs/recipe.json" --verify
  [ "$status" -eq 0 ]
  assert_out "satisfied"
  assert_unchanged lin
  assert_no_call "mkfs"
  assert_no_call "mount "

  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 other
  run terraform_recipe_run lin "$stubs/recipe.json" --verify
  [ "$status" -eq 2 ]
  assert_out "root"
  assert_out "other"
}

# A UUID names one filesystem, so two partitions carrying the same label cannot make the root
# ambiguous: the declared UUID picks the partition, where a label resolves to whichever one the scan
# reached first.
@test "a declared uuid resolves the partition even when another partition shares its label" {
  owned lin pick
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  format_slice lin 3 "$LINUX2_START" "$LINUX2_N" ext4 nixos
  nodes lin
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  recipe_uuid "$stubs/recipe.json" root "$(uuid_of lin 3)"
  snapshot_regions lin "$LINUX_START" "$LINUX_N" "$LINUX2_START" "$LINUX2_N"

  run terraform_recipe_run lin "$stubs/recipe.json"
  [ "$status" -eq 0 ]
  assert_call "^mount -o noatime $disk_dir/lin.img3 $disk_dir/mnt$"
  assert_call "^mount .* $disk_dir/mnt$"
  assert_no_call "mkfs"
  assert_unchanged lin
}

# A UUID the drive does not carry is not a partition that moved: it is a recipe copied from another
# drive, and taking the entry anyway would install onto somebody else's filesystem.
@test "a uuid this drive does not carry refuses the run before anything is written" {
  owned lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  recipe_uuid "$stubs/recipe.json" root "e7b0e010-10bf-4984-b941-5c7c182d1b74"
  snapshot lin

  run terraform_recipe_run lin "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "e7b0e010-10bf-4984-b941-5c7c182d1b74"
  assert_out "no partition on"
  assert_out "mkfs is never given a UUID"
  assert_no_call "mkfs"
  assert_no_call "sfdisk --append"
  assert_unchanged lin
}

# mkfs is never given a UUID, so a UUID can only describe a filesystem that already exists. Declaring
# one on a partition this run is about to format is asking for a UUID mkfs will invent.
@test "a uuid declared on a blank partition refuses before any format" {
  owned blank blank
  nodes blank
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  recipe_uuid "$stubs/recipe.json" root "BBD9-580F"
  snapshot blank

  run terraform_recipe_run blank "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "mkfs is never given a UUID"
  assert_out "terraform.json"
  assert_no_call "mkfs"
  assert_unchanged blank
}

# A uuid outside [A-Za-z0-9-] would reach a device path with a slash or a space in it, the same rule
# lib/filesystems.nix enforces at eval.
@test "a recipe uuid that is not a filesystem UUID refuses before any read of the drive" {
  owned lin blank
  nodes lin
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  recipe_uuid "$stubs/recipe.json" root "../../boot"
  snapshot lin

  run terraform_recipe_run lin "$stubs/recipe.json"
  [ "$status" -eq 2 ]
  assert_out "not a filesystem UUID"
  assert_unchanged lin
}

# The reproduction records nothing: folding a recipe onto the drive is a separate act, so a run that
# failed leaves no recipe behind. install.sh's terraform stage calls --record after its verification.
@test "a recipe run writes no recipe; --record folds the UUIDs onto the mounted root afterwards" {
  image own blank
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --force
  [ "$status" -eq 0 ]
  [ ! -e "$disk_dir/mnt/terraform.json" ]
  # The nodes the run formatted must not be re-cut from the image: --record reads those filesystems.
  TF_NODES=0 run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --record
  [ "$status" -eq 0 ]
  jq -e --arg esp "$(uuid_of own 1)" --arg root "$(uuid_of own 2)" '(.partitions[] | select(.name == "esp") | .uuid) == $esp and (.partitions[] | select(.name == "root") | .uuid) == $root and .owns == true' "$disk_dir/mnt/terraform.json" >/dev/null
  # The layout itself is preserved: a recorded recipe is the same recipe with UUIDs added.
  jq -e '.partitions[] | select(.name == "root") | .size == "54M" and .mount == "/"' "$disk_dir/mnt/terraform.json" >/dev/null
  assert_out "terraform.json"
}

# Nothing is recorded when the recipe already names every filesystem, so a folded repo re-runs clean.
@test "--record writes nothing when the recipe already declares every uuid" {
  owned lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  recipe_uuid "$stubs/recipe.json" esp "$(uuid_of lin 1)"
  recipe_uuid "$stubs/recipe.json" root "$(uuid_of lin 2)"
  TF_NODES=0 run terraform_recipe_run lin "$stubs/recipe.json" --disk "$disk_dir/lin.img" --record
  [ "$status" -eq 0 ]
  [ ! -e "$disk_dir/mnt/terraform.json" ]
}

# --record writes a file, so a dry run has nothing to record.
@test "--record under --dry-run refuses and writes nothing" {
  owned own blank
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --record --dry-run
  [ "$status" -eq 2 ]
  assert_out "--dry-run writes nothing"
  [ ! -e "$disk_dir/mnt/terraform.json" ]
}

@test "--record without a recipe refuses" {
  owned own blank
  run terraform_run own --record
  [ "$status" -eq 2 ]
  assert_out "--recipe is required"
  [ ! -e "$disk_dir/mnt/terraform.json" ]
}

# --emit is the fold on an installed host, so the UUIDs have to be in what it prints.
@test "--emit prints the uuid of every filesystem it found" {
  owned lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  snapshot_regions lin "$LINUX_START" "$LINUX_N" "$ESP_START" "$ESP_N"

  run emit_run --emit
  [ "$status" -eq 0 ]
  jq -e --arg esp "$(uuid_of lin 1)" --arg root "$(uuid_of lin 2)" '[.partitions[].uuid] == [$esp, $root]' \
    "$stubs/emit.json" >/dev/null
  assert_unchanged lin
}

# A recipe folded in from a recorded file describes those filesystems. Reformatting the partition gives
# it a different UUID, and the recipe then names a filesystem the drive does not hold.
@test "--verify refuses a uuid the drive no longer carries" {
  owned lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  recipe_uuid "$stubs/recipe.json" root "$(uuid_of lin 2)"

  run terraform_recipe_run lin "$stubs/recipe.json" --verify
  [ "$status" -eq 0 ]

  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  run terraform_recipe_run lin "$stubs/recipe.json" --verify
  [ "$status" -eq 2 ]
  assert_out "uuid"
}

# Writing a fresh gpt table does not erase the old table's filesystem superblocks: the bytes stay in
# place. A partition this run created is therefore formatted even though blkid still sees the old one,
# which is what mkfs -f is for.
@test "owns=true --force formats the partitions it just made over the bytes the old table left" {
  owned own blank
  format_slice own 1 "$ESP_START" "$ESP_N" ext4 someone
  adopt own 1 "$ESP_START" "$ESP_N"
  format_slice own 2 "$LINUX_START" "$LINUX_N" ext4 someone2
  adopt own 2 "$LINUX_START" "$LINUX_N"
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:54M:/"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --force
  [ "$status" -eq 0 ]
  [ "$(type_of own 1)" = vfat ]
  [ "$(label_of own 1)" = boot ]
  [ "$(type_of own 2)" = ext4 ]
  [ "$(label_of own 2)" = nixos ]
}

# owns=true reproduces the layout, so a table with an entry the recipe never declared is a drive that
# does not match the recipe.
@test "--verify in owns mode refuses a table holding entries the recipe did not declare" {
  owned own pick
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --verify
  [ "$status" -eq 2 ]
  assert_out "extra"
}

# A drive with no table at all is the fresh-install case: a plan describes it, a verification says the
# layout is not on the drive yet.
@test "--verify in owns mode refuses a drive with no table, and a dry run plans one" {
  owned own bare
  recipe_file "$stubs/recipe.json" true "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  snapshot own
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --verify
  [ "$status" -eq 2 ]
  assert_out "not on this drive yet"
  run terraform_recipe_run own "$stubs/recipe.json" --disk "$disk_dir/own.img" --dry-run
  [ "$status" -eq 0 ]
  assert_out "root: create 16M"
  assert_unchanged own
}

# emit <args...> — the read-only recipe print. stdout and stderr are kept apart on purpose: stdout
# must be valid JSON on its own, because that is what a user redirects into
# hosts/<host>/terraform.json, and every line that tells a human what to change is stderr.
emit_run() {
  PATH="$stubs:$PATH" bash "$repo/terraform.sh" "$@" >"$stubs/emit.json" 2>"$stubs/emit.err"
}
assert_json() {
  jq -e "$1" "$stubs/emit.json" >/dev/null
}
assert_err() {
  grep -q -- "$1" "$stubs/emit.err"
}
assert_no_json() {
  [ ! -s "$stubs/emit.json" ]
}

@test "--emit prints the partitions the drive can show a filesystem for, as the reader accepts them" {
  owned lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  snapshot lin "$LINUX_START" "$LINUX_N"

  run emit_run --emit
  [ "$status" -eq 0 ]
  assert_json '.owns == false'
  assert_json '[.partitions[].fs] == ["vfat", "ext4"]'
  assert_json '[.partitions[].label] == ["boot", "nixos"]'
  # Sizes come off the table, exact and in a unit a human reads: a recipe whose size drifted from
  # the partition would fail the free-space precheck the moment it is resized.
  assert_json '[.partitions[].size] == ["8M", "16M"]'
  # Mounts are the one thing the drive cannot show, so they are guesses and stderr says so.
  assert_json '[.partitions[].mount] == ["/boot", "/"]'
  # Options are copied from the mount the host's config makes for that filesystem: a vfat ESP gets
  # the 0077 masks and ext4 gets noatime, so the emitted recipe says what the host will mount with.
  assert_json '[.partitions[] | (.options // "")] == ["fmask=0077,dmask=0077", "noatime"]'
  assert_err "options"
  # Read-only: no format, no mount, no partition write, and the bytes did not move.
  assert_no_call "mount "
  assert_no_call "sgdisk"
  assert_no_call "wipefs"
  assert_unchanged lin
}

@test "an emitted recipe round-trips: the run it describes adopts the drive and writes nothing" {
  owned lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  run emit_run --emit
  [ "$status" -eq 0 ]
  snapshot_regions lin "$LINUX_START" "$LINUX_N" "$ESP_START" "$ESP_N"

  run terraform_recipe_run lin "$stubs/emit.json"
  [ "$status" -eq 0 ]
  assert_out "drive $disk_dir/lin.img"
  assert_out "adopt"
  assert_unchanged lin

  # The verdict half of the round-trip: --verify alone reads the drive against the emitted recipe and
  # writes nothing. sync puts the run's formatting back into the image, which is what a real mkfs does
  # to a real partition, so the second read sees the first run's work.
  sync lin
  : >"$calls"
  run terraform_recipe_run lin "$stubs/emit.json" --verify
  [ "$status" -eq 0 ]
  assert_out "satisfied"
  assert_no_call "mkfs"
  assert_no_call "mount "
}

# A drive this host does not own gets its ESP from the drive, never from free space. A partition that
# holds vfat under some other label is somebody else's boot partition: the run has to refuse before
# appending anything, because appending an ESP and then refusing leaves the drive changed with
# nothing installed.
@test "a shared drive whose ESP holds somebody else's label is refused before anything is appended" {
  owned win
  format_slice win 1 "$ESP_START" "$NTFS_N" vfat EFIBOOT
  seed_region win "$NTFS_START" "$NTFS_N" W
  snapshot win
  entries_before=$(entries_json win)
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:rest:/"
  run terraform_recipe_run win "$stubs/recipe.json" --disk "$disk_dir/win.img"
  [ "$status" -eq 2 ]
  assert_out "$disk"
  assert_out "EFIBOOT"
  assert_no_call "sfdisk --append"
  assert_no_call "mkfs"
  assert_unchanged win
  [ "$(entries_json win)" = "$entries_before" ]
}

@test "flags mode does not take a blank Basic Data partition for the ESP" {
  owned bd
  snapshot bd
  TF_FORCE=0 run terraform_run bd
  [ "$status" -eq 2 ]
  assert_no_call "mkfs"
  assert_out "no FAT partition"
  assert_unchanged bd
}

@test "--emit leaves out partitions it cannot reproduce and names why" {
  image winblank winblank Microsoft/BOOT
  snapshot winblank

  run emit_run --emit
  [ "$status" -eq 0 ]
  # The ESP is the only partition the drive can show a filesystem for. The blank Linux partition is
  # deliberately not emitted: nothing on the drive says what it should hold, and a partition emitted
  # with a guessed filesystem would be a recipe that formats something nobody asked for.
  assert_json '.partitions | length == 1'
  assert_json '.partitions[0].fs == "vfat"'
  assert_json '.partitions[0].mount == "/boot"'
  assert_err "basic-data"
  assert_err "linux"
  assert_err "no filesystem"
  # The recipe it printed cannot stand alone: the root has to be declared by the human.
  assert_err "/"
  [ "$(type_of winblank 4)" = "" ]
  assert_unchanged winblank
}

@test "the emitted recipe plus the root partition the operator declares runs on a Windows drive" {
  image winblank winblank Microsoft/BOOT
  run emit_run --emit
  [ "$status" -eq 0 ]
  assert_json '.partitions | length == 1'

  # What the operator adds is exactly the one thing the drive could not show. The ESP carries no
  # filesystem label here, which is the normal case on a Windows drive, and the run still names it.
  # The size is left off on purpose: the partition is whatever Windows left, and sfdisk writes it at
  # that exact geometry, so an entry that adopts it asks for nothing.
  jq '.partitions += [{name: "root", label: "nixos", fs: "ext4", mount: "/"}]' "$stubs/emit.json" >"$stubs/declared.json"

  snapshot winblank
  run terraform_recipe_run winblank "$stubs/declared.json"
  [ "$status" -eq 0 ]
  assert_out "esp: adopt"
  assert_out "root: format ext4"
  [ "$(type_of winblank 4)" = ext4 ]
  [ "$(label_of winblank 4)" = nixos ]
  mcopy -i "$disk_dir/winblank.img1" ::/EFI/Microsoft/BOOT/boot.efi "$disk_dir/winboot.efi"
  cmp "$disk_dir/loader.efi" "$disk_dir/winboot.efi"
  assert_unchanged winblank
}

@test "--emit refuses a drive with nothing to emit, and prints no recipe" {
  owned blank
  nodes blank
  snapshot blank

  run emit_run --emit
  [ "$status" -eq 2 ]
  assert_no_json
  assert_err "no filesystem"
  [ "$(type_of blank 1)" = "" ]
  assert_unchanged blank

  disk bare
  run emit_run --emit --disk "$disk_dir/bare.img"
  [ "$status" -eq 2 ]
  assert_err "no partition table"
}

@test "--emit takes a drive from lsblk only when there is exactly one" {
  disk lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  nodes lin
  disk twin blank
  nodes twin
  stub_lsblk "$disk_dir/lin.img" "$disk_dir/twin.img"

  run emit_run --emit
  [ "$status" -eq 2 ]
  assert_err "several disks"
  assert_no_json

  run emit_run --emit --disk "$disk_dir/lin.img"
  [ "$status" -eq 0 ]
  assert_json '[.partitions[].label] == ["boot", "nixos"]'

  # A recipe and an emitted recipe are opposite directions: refusing beats picking one silently.
  run emit_run --emit --recipe "$stubs/emit.json"
  [ "$status" -eq 2 ]
  assert_err "--recipe"
}

@test "the plan says adopt or format per partition, and a dry run writes nothing" {

  disk lin blank
  format_slice lin 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice lin 2 "$LINUX_START" "$LINUX_N" ext4 nixos
  recipe_file "$stubs/recipe.json" false "esp:boot:vfat:8M:/boot,root:nixos:ext4:16M:/"
  stub_lsblk "$disk_dir/lin.img"
  run terraform_recipe_run lin "$stubs/recipe.json" --dry-run
  assert_out "esp: adopt"
  assert_out "root: adopt"
  [ "$(type_of lin 1)" = vfat ]
  [ "$(type_of lin 2)" = ext4 ]

  disk blank
  stub_lsblk "$disk_dir/blank.img"
  run terraform_recipe_run blank "$stubs/recipe.json" --dry-run
  assert_out "esp: format vfat"
  assert_out "root: format ext4"
  [ "$(type_of blank 1)" = "" ]
  [ "$(type_of blank 2)" = "" ]
}

# ---- slice R6: appending into free space (ADR-c2cd97401185) ----

@test "a recipe entry no partition describes is appended into free space, existing entries untouched" {
  image grow win
  recipe_file "$disk_dir/grow.json" false "esp:boot:vfat:8M:/boot,nixos:nixos:ext4:16M:/"
  before=$(entries_json grow)

  run terraform_recipe_run grow "$disk_dir/grow.json"
  [ "$status" -eq 0 ]
  assert_out "nixos: create 16M"
  assert_call "sfdisk --append"

  after=$(entries_json grow)
  # The three entries that already existed come back byte-for-byte the same; only a fourth is added.
  [ "$(printf '%s' "$after" | jq -c '.[:3]')" = "$before" ]
  new=$(printf '%s' "$after" | jq -c '.[3]')
  [ "$(printf '%s' "$new" | jq -r '.name')" = nixos ]
  [ "$(printf '%s' "$new" | jq -r '.type')" = "$LINUX_TYPE" ]
  start=$(printf '%s' "$new" | jq -r '.start')
  size=$(printf '%s' "$new" | jq -r '.size')
  # It lands in the gap after the last foreign partition, and never overlaps one.
  [ "$start" -ge $((NTFS_START + NTFS_N)) ]
  [ "$size" -ge 32768 ]
  [ "$(type_of grow 4)" = ext4 ]
  [ "$(label_of grow 4)" = nixos ]
  assert_unchanged grow
}

@test "a recipe asking for more than the free space holds refuses before anything is written" {
  owned tight
  seed_region tight "$NTFS_START" "$NTFS_N" W
  nodes tight
  recipe_file "$disk_dir/tight.json" false "esp:boot:vfat:8M:/boot,nixos:nixos:ext4:44M:/"
  before=$(entries_json tight)
  run terraform_recipe_run tight "$disk_dir/tight.json"
  [ "$status" -eq 2 ]
  assert_out "no free gap holds it"
  [ "$(entries_json tight)" = "$before" ]
  assert_no_call "mkfs"
  assert_no_call "sfdisk --append"
}

@test "appending a partition needs the confirm gate" {
  owned gate esp
  nodes gate
  recipe_file "$disk_dir/gate.json" false "esp:boot:vfat:8M:/boot,nixos:nixos:ext4:16M:/"
  before=$(entries_json gate)
  TF_FORCE=0 run terraform_recipe_run gate "$disk_dir/gate.json"
  [ "$status" -eq 2 ]
  assert_out "needs a confirmation and there is no terminal"
  [ "$(entries_json gate)" = "$before" ]
  assert_no_call "mkfs"
}

@test "a second run adopts the partition the first one appended and writes nothing" {
  owned twice esp
  nodes twice
  recipe_file "$disk_dir/twice.json" false "esp:boot:vfat:8M:/boot,nixos:nixos:ext4:16M:/"
  run terraform_recipe_run twice "$disk_dir/twice.json"
  [ "$status" -eq 0 ]
  sync twice
  before=$(entries_json twice)
  : >"$calls"
  run terraform_recipe_run twice "$disk_dir/twice.json"
  [ "$status" -eq 0 ]
  assert_out "nixos: adopt"
  assert_no_call "mkfs"
  assert_no_call "sfdisk --append"
  [ "$(entries_json twice)" = "$before" ]
}

# The fixture factories below are what a new scenario is built from: one call for the drive, one for
# "this host owns it", one snapshot/compare for byte identity. They live in disk-fixture.bash.

# owned <name> [shape] is disk + stub_lsblk in one call; those two are always paired.
@test "owned makes a drive a discovery candidate in one call" {
  owned own bare
  run cat "$stubs/disks"
  assert_out "own.img"
}

# A region that moved must be named. "unchanged" that does not say which region moved is not a proof.
@test "assert_unchanged names the byte region that moved" {
  owned win
  seed_region win "$MSR_START" "$MSR_N" M
  snapshot win "$MSR_START" "$MSR_N"
  # Non-zero bytes: the sector-range region is zeros, and writing zeros there would prove nothing.
  dd if=/dev/zero bs=512 count=1 | tr '\0' 'Z' |
    dd of="$disk_dir/win.img" bs=512 seek="$MSR_START" conv=notrunc status=none
  run assert_unchanged win
  assert_out "CHANGED win $MSR_START $MSR_N"
}

# The GPT header is its own item, checked separately from every region.
@test "assert_unchanged names the partition table when the table moves" {
  owned win
  snapshot win
  seed_region win 0 64 Z
  run assert_unchanged win
  assert_out "CHANGED win table"
}

# fixture_setup_file builds the shapes in the background, so a job that dies leaves a template
# missing -- and every test's `disk <shape>` copy would then fail inside the fixture rather than on
# an assertion. This is the fixture's own check, not a test of terraform.sh.
@test "every drive shape the suite copies exists" {
  run bash -c 'for s in bare raw esp blank win winblank pick tight full espghost bd pre-btrfs pre-ext4 pre-xfs; do
    [ -f "$template_dir/$s.img" ] || echo "missing=$s"
  done'
  assert_no_out "missing="
}

# A drive with no partition table must not read as "no entries": entries_json is what the
# byte-identity assertions compare, and an empty value on both sides of a run compares equal, so a
# swallowed sfdisk failure is the one way this tier can pass on a wiped GPT (ADR-b77ec913151f).
@test "entries_json names a drive with no partition table" {
  dd if=/dev/zero of="$disk_dir/bare.img" bs=1M count=1 status=none
  run entries_json bare
  [ "$status" != 0 ]
  assert_out "bare"
}
