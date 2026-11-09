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
# The ESP GUID, not the FAT32 GUID: firmware scans partitions by the ESP GUID (UEFI 2.7 §12.3), which
# is what the VM's own ESP carries (`C12A7328…`, seen on nvme0n1p1 on 192.168.1.237).
LINUX_TYPE=0FC63DAF-8483-4772-8E79-3D69D8457574
ESP_TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
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
# A Linux root that fills the drive, so a recipe declaring `rest` has nothing left to take.
FULL_START=18432 FULL_END=129023

fixture_dir() { disk_dir="$(mktemp -d)"; }
fixture_teardown() { rm -rf "$disk_dir"; }

# build_shape <name> [index:start:end:type:name...] — a sparse image with a real GPT, built once.
# Shapes are built once per file and copied per test; building an image inside a test is what made
# this suite slow. It writes with sfdisk, the same tool terraform.sh uses: start and size in exact
# sectors, so sfdisk follows the geometry the test names instead of aligning it, and GPT wants a
# type GUID, which every type constant above already is.
build_shape() {
  local img="$template_dir/$1.img" spec layout lines=() names=()
  truncate -s 64M "$img"
  shift
  for spec in "$@"; do
    IFS=: read -r idx start end type name <<<"$spec"
    lines+=("$(printf '%s %s %s' "$start" "$((end - start + 1))" "$type")")
    names+=("$idx:$name")
  done
  [ "${#lines[@]}" -gt 0 ] || return 0
  layout=$(printf '%s\n' "${lines[@]}")
  sfdisk -X gpt "$img" <<<"$layout" >/dev/null
  # Names are a second pass: sfdisk writes the table from stdin and labels one partition per call.
  for n in "${names[@]}"; do
    sfdisk --part-label "$img" "${n%%:*}" "${n#*:}" >/dev/null
  done
}

# fixture_setup_file / fixture_teardown_file — the drive shapes every test needs, built once for the
# file. `bare` is an image with no partition table; `raw` is one holding a filesystem and no table.
fixture_setup_file() {
  # bats runs setup_file in its own process, so the template location has to be exported for the
  # tests, which each run in a separate one.
  template_dir="$(mktemp -d)"
  export template_dir
  local esp="1:$ESP_START:$ESP_END:$ESP_TYPE:esp"
  local root="2:$LINUX_START:$LINUX_END:$LINUX_TYPE:root"
  local msr="2:$MSR_START:$MSR_END:$MSR_TYPE:msr"
  local ntfs="3:$NTFS_START:$NTFS_END:$NTFS_TYPE:basic-data"
  # Each shape is its own file, so the shapes build concurrently. `wait` is the barrier -- a failed
  # shape fails setup_file, so a background job cannot silently leave a missing template.
  {
    build_shape bare
    build_shape raw
    mkfs.ext4 -q -L someone "$template_dir/raw.img" >/dev/null 2>&1
  } &
  build_shape esp "$esp" &
  build_shape blank "$esp" "$root" &
  build_shape win "$esp" "$msr" "$ntfs" &
  build_shape winblank "$esp" "$msr" "$ntfs" "4:$WIN_LINUX_START:$WIN_LINUX_END:$LINUX_TYPE:linux" &
  build_shape pick "$esp" "2:$LINUX_START:$LINUX_END:$LINUX_TYPE:foreign-root" "3:$LINUX2_START:$LINUX2_END:$LINUX_TYPE:nixos-root" &
  build_shape tight "$esp" "2:$NTFS_START:$NTFS_END:$NTFS_TYPE:basic-data" &
  build_shape full "$esp" "2:$FULL_START:$FULL_END:$LINUX_TYPE:root" &
  # A blank ESP carrying the ESP GUID under a name that is not `esp`: adoption has to match the
  # partition type, because a Windows or firmware-created ESP names itself something else.
  build_shape espghost "1:$ESP_START:$ESP_END:$ESP_TYPE:firmware" &
  # A drive with no ESP at all: one blank Basic Data partition. Flags mode must not fill it in as a
  # boot partition — a blank Basic Data partition says nothing about what it should hold.
  build_shape bd "1:$ESP_START:$ESP_END:$NTFS_TYPE:basic-data" &
  wait

  # The drives whose tests only *read* a filesystem that already exists (they assert mkfs is never
  # called) are formatted once here rather than by every test: a real mkfs per test is what made
  # them the slowest tests in the tier. `disk <name> <shape>` copies the formatted bytes, and
  # `nodes` re-derives the partition files from the image, so no slice file is copied. Concurrent,
  # because build_preformatted borrows disk_dir with `local` and writes a differently named image.
  build_preformatted pre-btrfs 128M btrfs &
  build_preformatted pre-ext4 128M ext4 &
  build_preformatted pre-xfs 320M xfs &
  wait
}

fixture_teardown_file() { rm -rf "$template_dir"; }

# build_preformatted <name> <size> <root-fs> — an ESP and a root that already hold real filesystems,
# at the geometry those tests wrote: ESP at 2048..18431, root from 20480 to the end of the drive.
# The sizes are the smallest that work: mkfs.btrfs refuses a filesystem below ~114MB and mkfs.xfs
# below ~300MB, and the ESP takes 9MB of the drive.
build_preformatted() {
  local name="$1" size="$2" fs="$3" sect img="$template_dir/$1.img"
  # slice and adopt read $disk_dir; `local` borrows the template directory for the duration of this
  # call and puts the caller's value back on return, which is what makes three of these at once safe
  # -- each writes a differently named image, and no caller has to restore a global by hand.
  local disk_dir="$template_dir"
  truncate -s "$size" "$img"
  printf '2048 16384 %s\n20480\n' "$ESP_TYPE" | sfdisk -X gpt "$img" >/dev/null 2>&1
  sect=$(sfdisk --json "$img" | jq -r '.partitiontable.partitions[1].size')
  format_slice "$name" 1 "$ESP_START" "$ESP_N" vfat boot
  format_slice "$name" 2 20480 "$sect" "$fs" nixos
  # adopt writes back densely, so the zeros between the filesystems land in tmpfs as real pages.
  # The image is freshly truncated and nothing here overwrote data, so punching those holes out is
  # safe and keeps three big shapes from costing RAM the tests never read.
  fallocate --dig-holes "$img"
}

# disk <name> [shape] — this test's own copy of a template, so every test starts from the bytes the
# shape was built with and nothing a test writes reaches another test. `--sparse=always` keeps the
# copy's holes as holes: the images live in tmpfs, where written pages are charged to the scope, so
# a dense copy of a 64M image costs RAM the test never reads.
disk() { cp --reflink=auto --sparse=always "$template_dir/${2:-$1}.img" "$disk_dir/$1.img"; }

# slice <disk> <index> <start> <count> — the partition as its own file, named as sfdisk names it.
# `conv=sparse` skips the zero blocks of a blank partition, which is what blkid reads as no
# signature either way.
slice() {
  dd if="$disk_dir/$1.img" of="$disk_dir/$1.img$2" bs=512 skip="$3" count="$4" conv=sparse status=none
}

# adopt <disk> <index> — the slice written back into the image, which is what a real mkfs would do
# to a real partition. Dense on purpose: zeros here overwrite bytes the image already holds, so
# `conv=sparse` would leave a foreign partition's data behind and break the byte-identity checks.
adopt() { dd if="$disk_dir/$1.img$2" of="$disk_dir/$1.img" bs=512 seek="$3" count="$4" conv=notrunc status=none; }

table_checksum() { dd if="$disk_dir/$1.img" bs=1M count=1 status=none | md5sum | cut -d' ' -f1; }

# partitions <disk> — every partition as "node start size", straight from the drive. nodes and sync
# are the same enumeration in opposite directions, and this runs once per test, so one sfdisk+jq
# pair here is what `terraform_run` used to pay twice.
partitions() {
  sfdisk --json "$disk_dir/$1.img" | jq -r '.partitiontable.partitions[] | "\(.node) \(.start) \(.size)"'
}

# entries_json <disk> — the partition entries as the drive reports them. Tests compare this before and
# after a run: appending may add an entry, but an entry that already exists must come back identical.
# A drive that cannot be read must fail here, not answer "": an empty value on both sides of a run
# compares equal, so a swallowed sfdisk failure would pass a byte-identity check on a wiped GPT.
entries_json() {
  local json
  # sfdisk's status is checked separately: with an empty stdin jq prints nothing and exits 0, so a
  # pipeline would swallow "does not contain a recognized partition table" exactly as before.
  json=$(sfdisk --json "$disk_dir/$1.img") || {
    echo "entries_json: $1 has no partition table" >&2
    return 1
  }
  printf '%s\n' "$json" | jq -c '.partitiontable.partitions'
}
region_checksum() { dd if="$disk_dir/$1.img" bs=512 skip="$2" count="$3" status=none | md5sum | cut -d' ' -f1; }

# snapshot <name> [start count]... — record the GPT header checksum plus one byte region per
# (start, count) pair, into a file beside the image. assert_unchanged <name> re-reads every recorded
# item and names the one that moved; items stay separate checks, because "unchanged" that does not
# say which region moved is not a proof. A file rather than an array: bats runs each test in its own
# process, and an associative array declared in a sourced fixture does not survive that fork.
snapshot() {
  local name="$1"
  printf 'table - - %s\n' "$(table_checksum "$name")" >"$disk_dir/.snap-$name"
  snapshot_regions "$@"
}

# snapshot_regions <name> <start count>... — regions without the header, for a run that is *meant* to
# change the table (an append adds an entry), so its header must not be compared.
snapshot_regions() {
  local name="$1"
  shift
  while [ $# -ge 2 ]; do
    printf 'region %s %s %s\n' "$1" "$2" "$(region_checksum "$name" "$1" "$2")" >>"$disk_dir/.snap-$name"
    shift 2
  done
}

assert_unchanged() {
  local name="$1" kind start count stored now item moved=0
  while read -r kind start count stored; do
    if [ "$kind" = table ]; then
      item="table"
      now=$(table_checksum "$name")
    else
      item="$start $count"
      now=$(region_checksum "$name" "$start" "$count")
    fi
    if [ "$now" != "$stored" ]; then
      echo "CHANGED $name $item"
      moved=1
    fi
  done <"$disk_dir/.snap-$name"
  [ "$moved" = 0 ]
}

# owned <name> [shape] — the drive and its "this host owns it" candidate list in one call. `disk` and
# `stub_lsblk` are always paired, and a drive that is not a candidate is a test that silently
# discovers nothing.
owned() {
  disk "$@"
  stub_lsblk "$disk_dir/$1.img"
}

# image <name> [shape] [foreign-esp-dir] — a scenario's drive in one call: its own copy of the shape,
# listed as a discovery candidate, the boot metadata another OS left in the ESP plus recognizable bytes
# in the partitions that OS owns (when a dir is given), the nodes sfdisk would name, and a snapshot of
# every partition region the drive reports. Regions come off the drive, so a scenario pins the
# geometry sfdisk gave instead of hand-cut slices, and assert_unchanged names the region that moves.
# A scenario that must prove the GPT header too calls snapshot <name> beside this: appending rewrites
# the header, so regions alone stay comparable across an append. Seeding happens before the snapshot,
# because seed_region writes the image itself.
image() {
  local name="$1" shape="${2:-$1}" foreign="${3:-}" node start size
  owned "$name" "$shape"
  if [ -n "$foreign" ]; then
    esp_foreign "$name" "$foreign"
    while read -r node start size; do
      [ "$node" = "$disk_dir/$name.img1" ] || seed_region "$name" "$start" "$size" W
    done < <(partitions "$name")
  fi
  nodes "$name"
  while read -r start size; do
    snapshot_regions "$name" "$start" "$size"
  done < <(partitions "$name" | awk '{print $2, $3}')
}

# seed_region <disk> <start> <count> <byte> — recognizable bytes in a partition another OS owns, so a
# checksum that moves means the region was actually written rather than that it happens to be zeros.
seed_region() {
  dd if=/dev/zero bs=1 count="$3" | tr '\0' "$4" | dd of="$disk_dir/$1.img" bs=1 seek="$2" conv=notrunc status=none
}
type_of() { blkid -o value -s TYPE "$disk_dir/$1.img$2" 2>/dev/null || true; }
label_of() { blkid -o value -s LABEL "$disk_dir/$1.img$2" 2>/dev/null || true; }
# The UUID a fixture filesystem carries, which is what a recipe may declare and what a run records.
uuid_of() { blkid -o value -s UUID "$disk_dir/$1.img$2" 2>/dev/null || true; }

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
  # btrfs-progs refuses a device below ~114MB, so a btrfs slice has to be a big one.
  if [ -n "$label" ]; then
    case "$fs" in
      vfat) mkfs.vfat -F 32 -n "$label" "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      ext4) mkfs.ext4 -q -T ext4 -L "$label" "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      btrfs) mkfs.btrfs -f -q -L "$label" "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      xfs) mkfs.xfs -f -q -L "$label" "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
    esac
  else
    case "$fs" in
      vfat) mkfs.vfat -F 32 "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      ext4) mkfs.ext4 -q -T ext4 "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      btrfs) mkfs.btrfs -f -q "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
      xfs) mkfs.xfs -f -q "$disk_dir/$disk.img$idx" >/dev/null 2>&1 ;;
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
    dd if="$disk_dir/$1.img" of="$node" bs=512 skip="$start" count="$size" conv=sparse status=none
  done < <(partitions "$1")
}

# sync <disk> — the partitions written back into the image, which is what a real mkfs does to a real
# partition. It is what lets a second run see the first run's work instead of the original zeros.
sync() {
  while read -r node start size; do
    dd if="$node" of="$disk_dir/$1.img" bs=512 seek="$start" count="$size" conv=notrunc status=none
  done < <(partitions "$1")
}

# recipe_file <file> <owns> <entries> — a terraform.json the shipped reader parses. Entries are
# comma-separated name:label:fs:size:mount. It is written with jq so the file is real JSON, not a
# shape the test assumes.
recipe_file() {
  local file="$1" owns="$2" entries="$3"
  jq -n --arg owns "$owns" --arg entries "$entries" '{
    owns: ($owns == "true"),
    partitions: ($entries / "," | map(. as $e | ($e / ":") | {name: .[0], label: .[1], fs: .[2], size: .[3], mount: .[4], options: (.[5] // null)} | with_entries(select(.value != null))))
  }' >"$file"
}

# recipe_uuid <file> <name> <uuid> — declare a filesystem UUID on one partition of a recipe, the way
# a recorded recipe carries them. Written with jq so the file stays real JSON.
recipe_uuid() {
  jq --arg name "$2" --arg uuid "$3" '(.partitions[] | select(.name == $name)) += {uuid: $uuid}' \
    "$1" >"$1.new" && mv "$1.new" "$1"
}

# stub_lsblk <paths...> — the candidate set discovery enumerates. A fixture image stands in for a
# /dev name: the reader accepts a path that exists, which is what lets discovery run on files.
# With no paths it reports no disk at all, which is the default setup state. SIZE is included
# because the free-space precheck needs the drive's own length, and a fixture's length is its file.
stub_lsblk() {
  : >"$stubs/disks"
  [ $# -gt 0 ] && printf '%s\n' "$@" >>"$stubs/disks"
  stub lsblk <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$calls"
printf '{"blockdevices":['
first=1
while read -r p; do
  [ -n "\$p" ] || continue
  [ "\$first" = 1 ] || printf ','
  printf '{"name":"%s","type":"disk","rm":false,"size":%s}' "\$p" "\$(wc -c <"\$p")"
  first=0
done < "$stubs/disks"
printf ']}\n'
EOF
}

# terraform_recipe_run <disk> <recipe> [flags] — the shipped script driven by a recipe alone, so no
# flag names the drive, the filesystem or a device path.
terraform_recipe_run() {
  local disk="$1" recipe="$2"
  shift 2
  # A read-only mode (--record) reads the filesystems a previous call in the same test formatted,
  # so the nodes must be left as they are. Re-cutting them from the image wipes those filesystems.
  if [ "${TF_NODES:-1}" = 1 ]; then nodes "$disk"; fi
  PATH="$stubs:$PATH" INSTALL_FORCE="${TF_FORCE:-1}" bash "$repo/terraform.sh" \
    --recipe "$recipe" --mount "$disk_dir/mnt" "$@"
}

# terraform_run — the shipped script against the fixture. mount and findmnt stay stubbed (they take
# root); sgdisk, wipefs, parted and fdisk are stubbed to fail, so a partition write by any of them
# is caught on the
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
