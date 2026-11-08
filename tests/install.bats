#!/usr/bin/env bats
# install.sh against PATH stubs: which stage runs, what it confirms, what it refuses. No root, no
# real disk, no eval. The destructive contract is the point: nothing reaches the drive until the
# operator says yes to that one step, and prepare must leave the partition table byte-identical.
load helpers

setup() {
  harness_stub_dir
  # ownsWholeDisk arrives as `builtins.toString` prints it: `1` for true, empty for false.
  printf '1\n' >"$stubs/owned"
  printf 'disk\n' >"$stubs/disk_type"
  printf '0\n' >"$stubs/mounted"
  printf '' >"$stubs/mounted_at"
  printf 'table\n' >"$stubs/table"
  printf '0\n' >"$stubs/dd_calls"
  # One eval of the host config answers five facts: who owns the drive, what its mounts name, and
  # where it mounts them. The suite answers them from files, not by evaluating.
  printf '/dev/disk/by-label/nixos\n' >"$stubs/root_device"
  printf 'ext4\n' >"$stubs/root_fs"
  printf '/dev/disk/by-label/boot\n' >"$stubs/esp_device"
  # The mount paths the host's config declares, on one line. `/` and `/boot` is the set a host whose
  # root filesystem holds no subvolumes declares; a suite that wants a btrfs tree overrides this.
  printf '/ /boot\n' >"$stubs/mount_paths"

  stub nix <<EOF
#!/usr/bin/env bash
echo "nix \$*" >> "$calls"
args="\$*"
store=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --store) store="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "\$args" in
  *ownsWholeDisk*)  printf '%s\n%s\n%s\n%s\n%s\n' "\$(cat "$stubs/owned")" "\$(cat "$stubs/root_device")" "\$(cat "$stubs/root_fs")" "\$(cat "$stubs/esp_device")" "\$(cat "$stubs/mount_paths")" ;;
  *osUsernames*)    printf 'josh\n' ;;
  *adminUsernames*) printf '%s\n' "\${ADMIN-josh}" ;;
  *substituters*)   printf 'https://cache.example/x\n' ;;
  *trustedPublicKeys*) printf 'cache.example:2\n' ;;
  *) exit 1 ;;
esac
EOF

  stub lsblk <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$calls"
# /dev/zram0 is absent unless the suite says it is there, so the zram branch is deterministic.
case "\$*" in
  */dev/zram0*) printf '%s\n' "\${ZRAM:-}" ;;
  *NAME,TYPE,RM*) printf '%s\n' "\${DISKS-vda disk 0}" ;;
  *PKNAME*)
    # A device the host declares that this machine does not have: lsblk exits non-zero, which is
    # exactly the read install.sh must survive in order to name the missing device.
    if [ "\${LSBLK_MISSING:-0}" = 1 ]; then exit 2; fi
    printf 'vda\n' ;;
  *) cat "$stubs/disk_type" ;;
esac
EOF

  # The ISO's RAM budget is what decides whether zram is offered; /proc/meminfo is stubbed so the
  # branch does not depend on how much the test machine happens to have free.
  stub awk <<EOF
#!/usr/bin/env bash
echo "awk \$*" >> "$calls"
printf '%s\n' "\${MEM_AVAIL:-3145728}"
EOF

  # dd is what reads the partition table, so the stub is where a mid-run change can be faked.
  stub dd <<EOF
#!/usr/bin/env bash
echo "dd \$*" >> "$calls"
n=\$(cat "$stubs/dd_calls")
printf '%s\n' "\$((n + 1))" > "$stubs/dd_calls"
if [ "\$DD_MUTATE" = 1 ] && [ "\$n" != 0 ]; then echo changed-table; else cat "$stubs/table"; fi
EOF

  # The scratch store is a tmpfs install.sh creates itself, so it is never already there. A mount of
  # a real device counts as the root being mounted, which is what terraform.sh's second run sees.
  # util-linux findmnt answers for a mountpoint and never for a directory inside one: a shared drive
  # mounts the root partition at $root, so its store is a directory inside that filesystem, not a
  # mount of its own. The old stub answered any path once a mount had happened, which hid that.
  stub findmnt <<EOF
#!/usr/bin/env bash
echo "findmnt \$*" >> "$calls"
case "\$*" in *scratch*) exit 1 ;; esac
path="\${@:\$#}"
src="\${TMPFS:-/dev/vda2}"
# Each mount is recorded as "<target> <device>", so a mount of the ESP at /mnt/boot never answers
# for /mnt. A line naming only a target is the fake terraform.sh's answer, and gets the default src.
# grep is stubbed in this suite, so the file is read line by line instead.
while read -r target device; do
  if [ "\$target" = "\$path" ]; then echo "\${device:-\$src}"; exit 0; fi
done < "$stubs/mounted_at"
if [ "\$(cat "$stubs/mounted" 2>/dev/null)" = 1 ] && [ "\$path" = /mnt/nix ]; then echo "\$src"; exit 0; fi
exit 1
EOF

  # terraform.sh reads the table and the signatures: a Windows-shaped drive with a Linux partition
  # last. Signatures are per partition, so the suite can make any of them blank.
  stub sfdisk <<EOF
#!/usr/bin/env bash
echo "sfdisk \$*" >> "$calls"
printf '{"partitions":[{"node":"/dev/vda1","type":"C12A7EA9-344C-4175-A575-202976385741"},{"node":"/dev/vda2","type":"0FC63DAF-8483-4772-8E79-3D69D8457574"}]\n'
EOF

  stub blkid <<EOF
#!/usr/bin/env bash
echo "blkid \$*" >> "$calls"
case "\$*" in
  */dev/vda1*) t="\${ESP_TYPE:-vfat}" ;;
  */dev/vda2*) t="\${ROOT_TYPE-ext4}" ;;
  */dev/sda*) t="\${ISO_SIG:-}" ;;
  *) t="" ;;
esac
if [ -n "\$t" ]; then printf '%s\n' "\$t"; exit 0; fi
exit 2
EOF

  # terraform.sh reads the table and the recipe through jq; stubbing it keeps the suite off whatever
  # jq this machine happens to have. The recipe's `owns` is read from the file itself rather than a
  # fixture value, so the suite can never drift from the recipe committed in the tree.
  stub jq <<EOF
#!/usr/bin/env bash
echo "jq \$*" >> "$calls"
file=""
for a in "\$@"; do
  case "\$a" in *.json) file="\$a" ;; esac
done
case "\$*" in
*owns*)
  if [ -n "\$file" ]; then /usr/bin/grep -o '"owns": *[a-z]*' "\$file" | sed 's/.*: *//'; else printf 'false\n'; fi ;;
*) printf '/dev/vda1 C12A7EA9-344C-4175-A575-202976385741\n/dev/vda2 0FC63DAF-8483-4772-8E79-3D69D8457574\n' ;;
esac
EOF

  # Formatting is the destructive step: it is logged, never performed.
  for tool in mkfs.vfat mkfs.ext4 mkfs.btrfs; do
    stub "$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit \${MKFS_EXIT:-0}
EOF
  done

  # Only a mount of a real device counts as the root being mounted. The scratch store is a tmpfs
  # mkdir is stubbed too: terraform.sh creates the mount point for the ESP, and a real mkdir of /mnt
  # would write to this machine rather than to the fixture. Paths inside the fixture are created for
  # real, because install.sh then chmods and writes into its own scratch store.
  mkdir_real=$(command -v mkdir)
  stub mkdir <<EOF
#!/usr/bin/env bash
echo "mkdir \$*" >> "$calls"
case "\${@: -1}" in
  "$stubs"/*) exec "$mkdir_real" -p "\${@: -1}" ;;
esac
exit \${MKDIR_EXIT:-0}
EOF

  # install.sh creates itself, and recording that would make every later findmnt answer for /mnt —
  # which is how deploy could pass without terraform ever having run. Each mount is recorded against
  # its own target, so an ESP mounted at /mnt/boot never answers for /mnt.
  stub mount <<EOF
#!/usr/bin/env bash
echo "mount \$*" >> "$calls"
case "\$*" in
  */dev/*) printf '%s %s\n' "\${@: -1}" "\${@: -2}" >> "$stubs/mounted_at" ;;
esac
exit \${MOUNT_EXIT:-0}
EOF

  # systemd-run is not stubbed: the scope wrap must actually run the command it wraps, which is
  # what the stubs below would otherwise swallow.
  for tool in nixos-install nixos-enter reboot mkswap swapon modprobe tee chown; do
    env_name="${tool^^}"
    env_name="${env_name//-/_}"
    stub "$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit \${${env_name}_EXIT:-0}
EOF
  done

  # The ssh keys go into the installed tree, so `install` is where the suite can read back what
  # deploy wrote without touching /mnt on this machine. terraform.sh uses the same command to create
  # directories (-d), which is a no-op here: there is no /mnt to create in.
  stub install <<EOF
#!/usr/bin/env bash
echo "install \$*" >> "$calls"
for a in "\$@"; do
  [ "\$a" = "-d" ] && exit 0
done
dst=\${@:\$#}
src=""
for a in "\$@"; do
  case "\$a" in
    -*) ;;
    "\$dst") ;;
    *) src="\$a" ;;
  esac
done
mkdir -p "$stubs/root\$(dirname "\$dst")"
cp "\$src" "$stubs/root\$dst"
EOF

  # The keys come from whoever invoked the installer, so the suite pins that home instead of the
  # real one on this machine.
  stub getent <<EOF
#!/usr/bin/env bash
echo "getent \$*" >> "$calls"
printf '%s\n' "$stubs/home"
EOF

  # grep is how the reboot guard reads the installed system's shadow; mapping the file into the
  # stub tree keeps /mnt on this machine out of the suite. Anything outside /mnt (the call log,
  # which findmnt greps) is grepped as it really is.
  stub grep <<EOF
#!/usr/bin/env bash
echo "grep \$*" >> "$calls"
# Flags are kept: install.sh asks for ERE (-E) and dropping them would change the match.
flags=()
pat=""
file=""
for a in "\$@"; do
  case "\$a" in
    -*) flags+=("\$a") ;;
    *) if [ -z "\$pat" ]; then pat="\$a"; else file="\$a"; fi ;;
  esac
done
case "\$file" in
  /mnt*) file="$stubs/root\$file" ;;
 esac
 /usr/bin/grep "\${flags[@]}" "\$pat" "\$file"
EOF

  # nixos-install --no-root-passwd leaves placeholders, which is the state the reboot guard refuses.
  mkdir -p "$stubs/root/mnt/etc"
  printf 'root:!::\njosh:!::\n' >"$stubs/root/mnt/etc/shadow"
  printf 'josh:x:1000:100::/home/josh:/run/current-system/sw/bin/fish\n' >"$stubs/root/mnt/etc/passwd"
}

run_install() {
  # INSTALL_SCRATCH keeps the scratch store inside the stub dir instead of /run on this machine.
  INSTALL_SCRATCH="$stubs/scratch" PATH="$stubs:$PATH" bash "$repo/install.sh" "$@"
}

@test "--help prints usage and exits 0" {
  run run_install --help
  [ "$status" -eq 0 ]
  [[ $output == *"usage:"* ]]
  [[ $output == *"--stage"* ]]
}

@test "no host is refused, with nothing run" {
  run run_install
  [ "$status" -eq 2 ]
  assert_no_call "nix eval"
}

@test "prepare --dry-run runs nothing and leaves the partition table alone" {
  run run_install --dry-run --stage prepare methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "partition table unchanged"
  assert_no_call "mkfs"
  assert_no_call "nixos-install"
  assert_no_call "mkswap"
}

@test "prepare accepts a shared drive and reads the host's mounts, not a disko device" {
  printf '' >"$stubs/owned"
  run run_install --dry-run --stage prepare methyl
  [ "$status" -eq 0 ]
  assert_out "shares /dev/vda"
  assert_call "fileSystems"
  assert_no_call "disko.devices.disk"
  assert_out "partition table unchanged"
}

# A comma list is one call running the stages in the order given, so a stage already run is never
# prompted for again by a second invocation.
@test "--stage takes a comma list and runs the stages in the order given" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  TF_ROOT_DEVICE="$root_dev" INSTALL_FORCE=1 run run_install_in "$dir" --stage prepare,terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "prepare ok"
  assert_out "terraform ok"
  [ "$(grep -n 'prepare ok' <<<"$output" | cut -d: -f1)" -lt "$(grep -n 'terraform ok' <<<"$output" | cut -d: -f1)" ]
  assert_no_call "nixos-install"
}

# The list is not a sequence shortcut: terraform,postdeploy writes keys into the installed tree
# without ever running the install.
@test "--stage terraform,postdeploy writes keys without installing anything" {
  printf '1\n' >"$stubs/mounted"
  mkdir -p "$stubs/home/.ssh"
  printf 'ssh-ed25519 AAAAtest josh@laptop\n' >"$stubs/home/.ssh/authorized_keys"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  TF_ROOT_DEVICE="$root_dev" INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform,postdeploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "nixos-install"
  assert_call "^chown"
}

# An unknown name inside the list is refused before any stage runs, so prepare,bogus cannot leave a
# drive half-laid out.
@test "an unknown stage inside a comma list is refused with nothing run" {
  run run_install --dry-run --stage prepare,bogus methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "unknown stage bogus"
  assert_no_call "./terraform.sh"
  assert_no_call "nixos-install"
}

# A blank entry names nothing, which is a typo rather than a stage. A trailing comma is not a blank
# entry: `prepare,` is `prepare`.
@test "--stage with a blank entry is refused" {
  run run_install --dry-run --stage prepare,,terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "not blanks"
  assert_no_call "./terraform.sh"
}

@test "an owned host with no recipe is refused: there is no other layout declaration" {
  dir=$(recipe_repo methyl-nixos '')
  run run_install_in "$dir" --dry-run --stage terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "hosts/methyl-nixos/terraform.json must declare the layout"
  assert_no_call "./terraform.sh"
}

@test "prepare refuses a device that is not a whole disk" {
  printf 'part\n' >"$stubs/disk_type"
  run run_install --dry-run --stage prepare methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "not a whole disk"
}

@test "prepare refuses when the machine has no real drive to adopt" {
  # The host names a partition that is not here, and the only block devices are the ones that are
  # not a drive to install onto: terraform.sh would have nothing to adopt.
  printf '' >"$stubs/owned"
  LSBLK_MISSING=1 DISKS='' run run_install --stage prepare methyl
  [ "$status" -eq 2 ]
  assert_out "cannot tell which drive"
  assert_no_call "./terraform.sh"
}

@test "a shared drive whose partitions are still blank is adopted from the drive that has a table" {
  # terraform.sh formats the blank ESP and root, so the host's devices name nothing until it runs.
  # The drive is the one disk here that is neither removable nor the zram swap this script may have
  # added. propyl has no recipe, so this is the flags-mode command.
  printf '' >"$stubs/owned"
  LSBLK_MISSING=1 run run_install --dry-run --stage terraform propyl
  [ "$status" -eq 0 ]
  assert_out "shares /dev/vda"
  assert_out "[dry-run] ./terraform.sh --dry-run --disk /dev/vda"
}

@test "two candidate drives are refused rather than guessed" {
  printf '' >"$stubs/owned"
  LSBLK_MISSING=1 DISKS=$'vda disk 0\nvdb disk 0' run run_install --dry-run --stage terraform methyl
  [ "$status" -eq 2 ]
  assert_out "cannot tell which drive"
  assert_no_call "./terraform.sh"
}

@test "INSTALL_DRIVE names the target when no mount fact can name one" {
  # The VM guest's root is tmpfs, so neither the host's mount names nor blkid identify a drive.
  # The tier passes the drive it made; the whole-disk check in resolve still runs.
  printf '' >"$stubs/owned"
  LSBLK_MISSING=1 INSTALL_DRIVE=/dev/vdb run run_install --dry-run --stage terraform methyl
  [ "$status" -eq 0 ]
  assert_out "shares /dev/vdb"
  assert_out "[dry-run] ./terraform.sh --dry-run --recipe hosts/methyl/terraform.json --disk /dev/vdb --mount /mnt"
}

@test "INSTALL_DRIVE pointing at a partition is refused, not adopted" {
  printf '' >"$stubs/owned"
  printf 'part\n' >"$stubs/disk_type"
  LSBLK_MISSING=1 INSTALL_DRIVE=/dev/vda1 run run_install --dry-run --stage terraform methyl
  [ "$status" -eq 2 ]
  assert_out "/dev/vda1 is not a whole disk"
  assert_no_call "./terraform.sh"
}

@test "a drive presenting as the install ISO is not a candidate even when lsblk calls it a disk" {
  # The VM's ISO presents as /dev/sda: a dos table with iso9660 across the whole drive. It is media,
  # not a drive to install onto, and the only other disk here is the target.
  printf '' >"$stubs/owned"
  LSBLK_MISSING=1 DISKS=$'sda disk 0\nvda disk 0' ISO_SIG=iso9660 run run_install --dry-run --stage terraform methyl
  [ "$status" -eq 0 ]
  assert_out "shares /dev/vda"
}

@test "the install ISO's own devices and the zram swap are never adopted" {
  # The minimal ISO presents as a loop device and a removable sr0; prepare may have added /dev/zram0.
  # None of them is the drive being installed onto, so exactly one candidate remains.
  printf '' >"$stubs/owned"
  LSBLK_MISSING=1 DISKS=$'loop0 loop 0\nsr0 rom 1\nzram0 disk 0\nvda disk 0' run run_install --dry-run --stage terraform methyl
  [ "$status" -eq 0 ]
  assert_out "shares /dev/vda"
}

@test "a drive that already has partitions is still a whole drive" {
  # lsblk lists the disk and every partition it holds, so the check must look at the disk line
  # only: an installed drive is exactly the case terraform.sh is supposed to adopt.
  printf 'disk\npart\npart\n' >"$stubs/disk_type"
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "mounted from"
}

@test "prepare aborts if the partition table moved during the run" {
  DD_MUTATE=1 run run_install --dry-run --stage prepare methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "must never happen"
}

@test "low memory is offered as zram, and a refused offer stops the stage" {
  # bats closes stdin, so confirm() cannot ask: the refusal path is what a scripted run takes.
  run run_install --stage prepare methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "needs a confirmation and there is no terminal"
  assert_no_call "mkswap"
}

@test "forced prepare adds zram when RAM is short" {
  INSTALL_FORCE=1 run run_install --stage prepare methyl-nixos
  [ "$status" -eq 0 ]
  # disksize is a sysfs knob; writing the block device itself reports ENOSPC and leaves no swap.
  assert_call "^tee /sys/block/zram0/disksize"
  assert_no_call "^tee /dev/zram0"
  assert_call "^mkswap /dev/zram0"
  assert_call "^swapon /dev/zram0"
  assert_out "partition table unchanged"
}

# A recipe run records nothing itself: install.sh's terraform stage folds the recipe onto the drive,
# after the reproduction and its checks came back clean, so a run that failed leaves no recipe behind.
@test "the terraform stage folds the recipe onto the drive after the run and its checks" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  TF_ROOT_DEVICE="$root_dev" run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_calls "./terraform.sh --record --recipe hosts/methyl-nixos/terraform.json --disk /dev/vda --mount /mnt" 1
  # Folding is the stage's last act, so it follows the run that mounted the root.
  [ "$(grep -n -- '--record' "$calls" | cut -d: -f1)" -gt "$(grep -n -- ' --mount' "$calls" | head -1 | cut -d: -f1)" ]
  assert_out "recorded recipe at /mnt/terraform.json"
  assert_out "hosts/methyl-nixos/terraform.json"
}

# A dry run writes nothing anywhere, so it folds nothing.
@test "a dry-run terraform stage records nothing" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  TF_ROOT_DEVICE="$root_dev" run run_install_in "$dir" --dry-run --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "--record"
}

# A run that reported a failure left a layout that is not the recipe's; recording it would hand the
# operator a recipe describing the wrong drive.
@test "a failing terraform run records nothing" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  TF_EXIT=1 TF_ROOT_DEVICE="$root_dev" INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_no_call "--record"
}

# A recipe that already carries the UUIDs names every filesystem, so there is nothing to fold and the
# stage says nothing about it.
@test "a recipe that already carries uuids is not folded again" {
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  TF_ROOT_DEVICE="$root_dev" run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "--record"
  assert_no_out "recorded recipe"
}

# A host with no recipe has nothing to fold: its layout comes from flags, not from a file.
@test "a host with no recipe folds nothing" {
  printf '' >"$stubs/owned"
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo propyl-nixos "")
  TF_ROOT_DEVICE="$root_dev" run run_install_in "$dir" --stage terraform propyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "--record"
  assert_no_out "recorded recipe"
}

# A recipe that declares no UUID names filesystems by label, and a label is unique only within one
# drive: two partitions can answer to it. terraform.sh records the UUIDs it made onto the drive, so
# deploy refuses until the recipe carries them.
@test "deploy refuses a recipe that declares no filesystem UUID" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "hosts/methyl-nixos/terraform.json"
  assert_out "UUID"
  assert_out "terraform.json"
  # Nothing was installed, and the drive was not even asked about.
  assert_no_call "nixos-install"
  assert_no_call "./terraform.sh --verify"
}

# Folded in, deploy runs: the recipe names one filesystem, and the verdict still decides whether the
# drive needs changing.
@test "deploy runs from a recipe whose mounts carry UUIDs" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "^nixos-install --flake"
  assert_call "./terraform.sh --verify"
}

@test "deploy installs a system someone else built, when one is handed to it" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 INSTALL_SYSTEM=/nix/store/abc-nixos-system-methyl-nixos \
    run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  # The VM tier builds on the host and hands the closure over, so the guest never builds. That is
  # what keeps a flake evaluation off a machine with no spare RAM.
  assert_call "^nixos-install --system /nix/store/abc-nixos-system-methyl-nixos"
  assert_no_call "^nixos-install --flake"
}

@test "deploy adds zram before the build starts when RAM is short" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  # The build is what overflows the ISO's RAM, so the swap device has to exist before it, not after.
  [ "$(grep -n '^swapon /dev/zram0' "$calls" | cut -d: -f1)" -lt "$(grep -n '^nixos-install' "$calls" | cut -d: -f1)" ]
}

@test "deploy leaves an existing zram device alone" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  ZRAM=zram INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "^swapon"
  assert_no_call "^mkswap"
}

# One prompt for the whole stage, asked only when the drive is about to change. --verify is the
# verdict (read-only), and the answer is carried to terraform.sh as --force, so the stage never asks
# twice and a drive that already matches is never asked about (ADR-ca72f792db52, ADR-b77ec913151f).
@test "terraform asks once for the whole stage, and nothing touches the drive until it is answered" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  TF_VERIFY_EXIT=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "terraform will change /dev/vda"
  assert_out "needs a confirmation and there is no terminal"
  # The only terraform.sh call is the verdict; the destructive run never happened.
  assert_calls "./terraform.sh" 1
  assert_call "./terraform.sh --verify"
  assert_no_call "--force"
  assert_no_call "mkfs"
  assert_no_call "^mount /dev"
}

# A drive the verdict says is already the recipe's is not a destructive stage, so there is nothing to
# answer and the run adopts what the drive holds.
@test "terraform asks nothing when the drive already matches the recipe" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_out "terraform will change"
  assert_out "mounted from the layout hosts/methyl-nixos/terraform.json declares"
}

# The one yes the stage got is the permission for every destructive step inside it, so terraform.sh
# is run --force and asks for nothing itself.
@test "terraform carries a drive that needs changing to terraform.sh forced" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  printf '/mnt\n' >"$stubs/mounted_at"
  TF_VERIFY_EXIT=1 INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "terraform will change /dev/vda"
  assert_out "(forced)"
  assert_call "./terraform.sh --force --recipe hosts/methyl-nixos/terraform.json --disk /dev/vda --mount /mnt"
}

@test "terraform --dry-run prints the recipe command and writes nothing" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  run run_install_in "$dir" --dry-run --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "[dry-run] ./terraform.sh --dry-run --recipe hosts/methyl-nixos/terraform.json --disk /dev/vda --mount /mnt"
  assert_no_call "mkfs"
}

# A second run of the same recipe: the verdict says satisfied, so the stage asks nothing and the run
# adopts what the drive already holds instead of rebuilding it.
@test "terraform runs terraform.sh again on an installed layout, which adopts rather than rebuilds" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "mounted from the layout hosts/methyl-nixos/terraform.json declares"
  # The verdict, then the run, then the fold of the recipe onto the drive it just laid out.
  assert_calls "./terraform.sh" 3
}

# propyl is the host with no recipe, so these four are the flags-mode path: the host's own mounts name
# the partitions, and terraform.sh takes a filesystem and two device paths.
@test "terraform on a shared drive runs terraform.sh and never disko" {
  printf '' >"$stubs/owned"
  run run_install --dry-run --stage terraform propyl
  [ "$status" -eq 0 ]
  assert_out "[dry-run] ./terraform.sh --dry-run --disk /dev/vda --mount /mnt --root-fs ext4"
  assert_no_call "disko --mode"
  assert_no_call "mkfs"
}

@test "terraform on a shared drive adopts the signed partitions and mounts the declared root" {
  printf '' >"$stubs/owned"
  INSTALL_FORCE=1 run run_install --stage terraform propyl
  [ "$status" -eq 0 ]
  # Both partitions carry a signature, so nothing is formatted and only the root is mounted.
  assert_no_call "mkfs"
  # The root and the ESP are both mounted: deploy writes the boot loader into the ESP.
  assert_call "^mount -o noatime /dev/vda2 /mnt$"
  assert_call "^mount -o fmask=0077,dmask=0077 /dev/vda1 /mnt/boot$"
  assert_no_call "disko --mode"
  assert_out "mounted from the partitions propyl declares"
}

@test "terraform on a shared drive refuses to format a blank partition with nobody to ask" {
  printf '' >"$stubs/owned"
  ROOT_TYPE='' run run_install --stage terraform propyl
  [ "$status" -eq 2 ]
  assert_out "needs a confirmation and there is no terminal"
  assert_no_call "mkfs"
  assert_no_call "^mount /dev"
}

# The stage refuses before terraform.sh ever runs, so a device the host cannot resolve never gets a
# filesystem invented for it. terraform.bats covers that refusal itself.
@test "terraform on a shared drive refuses a blank partition the host names by UUID" {
  printf '' >"$stubs/owned"
  printf '/dev/disk/by-uuid/1234\n' >"$stubs/root_device"
  ROOT_TYPE='' run run_install --stage terraform propyl
  [ "$status" -eq 2 ]
  assert_out "needs a confirmation and there is no terminal"
  assert_no_call "./terraform.sh"
  assert_no_call "^mount /dev"
}

@test "terraform fails when the target store never got mounted" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  TF_VERIFY_EXIT=0 TF_EXIT=1 INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "terraform left /mnt unmounted"
}

# A failing terraform.sh can leave the root mounted from a layout that is not the recipe's -- stale
# superblocks under a fresh table is exactly that. The stage must not report ok.
@test "terraform reports failure even when the root stayed mounted" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  printf '/mnt\n' >"$stubs/mounted_at"
  TF_VERIFY_EXIT=0 TF_EXIT=1 INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "terraform.sh reported a failure"
  assert_no_out "terraform ok"
}

# A recipe file is the layout declaration for a host, shared or owned. It lives in a temp repo so the
# suite never writes into this working tree, and terraform.sh is faked there: install.sh's contract is
# the argv it passes, and terraform.bats covers what terraform.sh does with it. An empty recipe means
# no recipe file at all, which is what an owned host must be refused for.
recipe_repo() { # <host> <recipe json | ""> -> a repo dir holding hosts/<host>/terraform.json
  local dir="$stubs/repo" host="$1"
  mkdir -p "$dir/hosts/$host" "$dir/lib"
  cp "$repo/install.sh" "$dir/"
  cp "$repo/lib/confirm.sh" "$dir/lib/"
  printf '{}\n' >"$dir/flake.nix"
  if [ -n "$2" ]; then printf '%s\n' "$2" >"$dir/hosts/$host/terraform.json"; fi
  cat >"$dir/terraform.sh" <<EOF
#!/usr/bin/env bash
echo "./terraform.sh \$*" >> "$calls"
# The stage's contract is the mount: a run that is not a dry run and not a failure leaves the root
# mounted from a real device, which is what install.sh checks afterwards.
# --verify is the read-only verdict install.sh asks for before it prompts its one stage question, so
# it gets its own exit knob: 0 says the drive already holds what the recipe declares, 1 says the
# stage has destructive work to do.
case "\$*" in
  *--verify*) exit \${TF_VERIFY_EXIT:-0} ;;
  *--dry-run*) exit \${TF_EXIT:-0} ;;
  *) if [ "\${TF_EXIT:-0}" = 0 ]; then printf '%s\n' "\${@: \$#}" > "$stubs/mounted_at"; fi ;;
esac
exit \${TF_EXIT:-0}
EOF
  chmod +x "$dir/terraform.sh"
  printf '%s\n' "$dir"
}

# The recipe this flake commits for its owned host, read from the tree so the suite can never drift
# from the file install.sh acts on.
owned_recipe() { cat "$repo/hosts/methyl-nixos/terraform.json"; }

# The same recipe with a UUID on every partition, which is what terraform.sh records onto the drive
# and what deploy accepts. Inserted rather than retyped, so the fixture cannot drift from the file.
uuid_recipe() {
  sed 's/"label": /"uuid": "e7b0e010-10bf-4984-b941-5c7c182d1b74", "label": /' "$repo/hosts/methyl-nixos/terraform.json"
}

run_install_in() { # <repo dir> [install.sh args]
  local dir="$1"
  shift
  INSTALL_SCRATCH="$stubs/scratch" PATH="$stubs:$PATH" bash "$dir/install.sh" "$@"
}

@test "a shared host with a recipe is terraformed from the recipe, not from its mounts" {
  printf '' >"$stubs/owned"
  dir=$(recipe_repo methyl '{"owns": false, "partitions": [{"name":"esp","fs":"vfat","size":"8M","mount":"/boot"},{"name":"nixos","fs":"ext4","size":"rest","mount":"/"}]}')
  run run_install_in "$dir" --dry-run --stage terraform methyl
  [ "$status" -eq 0 ]
  assert_out "[dry-run] ./terraform.sh --dry-run --recipe hosts/methyl/terraform.json --disk /dev/vda --mount /mnt"
  assert_no_out "--root-fs"
}

# The recipe and the host fact must agree about who owns the drive. A recipe claiming a drive this
# host does not own is refused before any write.
@test "a recipe whose owns disagrees with flakeHost.ownsWholeDisk refuses before any write" {
  printf '' >"$stubs/owned"
  dir=$(recipe_repo methyl '{"owns": true, "partitions": []}')
  run run_install_in "$dir" --stage terraform methyl
  [ "$status" -eq 2 ]
  assert_out "ownsWholeDisk is false"
  assert_no_call "./terraform.sh"
  assert_no_call "mkfs"
}

@test "deploy verifies the drive against the recipe before it installs" {
  printf '' >"$stubs/owned"
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl '{"owns": false, "partitions": [{"name":"nixos","uuid": "e7b0e010-10bf-4984-b941-5c7c182d1b74", "fs":"ext4","size":"rest","mount":"/"}]}')
  INSTALL_FORCE=1 run run_install_in "$dir" --stage terraform methyl
  [ "$status" -eq 0 ]
  assert_call "--recipe hosts/methyl/terraform.json --disk /dev/vda --mount /mnt"
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl
  [ "$status" -eq 0 ]
  assert_call "./terraform.sh --verify --recipe hosts/methyl/terraform.json --disk /dev/vda"
  assert_call "nixos-install --flake .#methyl --root /mnt --no-root-passwd"
}

# `builtins.toString` of a bool is `1` for true and `""` for false, so a shared host answers with an
# empty line. methyl's committed recipe says owns=false, and that empty line is what it has to agree
# with — the suite pins the file in the tree so it can never drift from what install.sh acts on.
@test "methyl's committed recipe agrees with a host whose ownsWholeDisk Nix prints as empty" {
  printf '' >"$stubs/owned"
  dir=$(recipe_repo methyl "$(cat "$repo/hosts/methyl/terraform.json")")
  run run_install_in "$dir" --dry-run --stage terraform methyl
  [ "$status" -eq 0 ]
  assert_no_out "ownsWholeDisk"
  assert_out "--recipe hosts/methyl/terraform.json"
  assert_no_out "--root-fs"
}

# The same precondition on the host that owns its whole drive: the recipe committed in the tree is
# what deploy checks against.
@test "deploy verifies an owned drive against the recipe the layout was built from" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "./terraform.sh --verify --recipe hosts/methyl-nixos/terraform.json --disk /dev/vda"
  assert_call "nixos-install --flake .#methyl-nixos --root /mnt --no-root-passwd"
}

@test "deploy refuses when the drive no longer matches the recipe" {
  printf '' >"$stubs/owned"
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl '{"owns": false, "partitions": [{"name":"nixos","uuid": "e7b0e010-10bf-4984-b941-5c7c182d1b74", "fs":"ext4","size":"rest","mount":"/"}]}')
  TF_VERIFY_EXIT=1 INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl
  [ "$status" -eq 2 ]
  assert_out "no longer matches hosts/methyl/terraform.json"
  assert_no_call "nixos-install"
}

@test "deploy refuses before terraform" {
  INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "deploy needs terraform first"
  assert_no_call "nixos-install"
}

@test "deploy accepts a shared drive: the store is inside the root partition mounted at /mnt" {
  # A shared drive has no separate store mount -- terraform.sh mounts the host's root partition at
  # /mnt and nixos-install writes /mnt/nix/store inside it. findmnt does not answer for /mnt/nix,
  # so deploy has to accept the mount of /mnt itself. propyl has no recipe, so the mounts name the
  # partitions here.
  printf '' >"$stubs/owned"
  INSTALL_FORCE=1 run run_install --stage terraform propyl
  [ "$status" -eq 0 ]
  assert_call "mount -o noatime /dev/vda2 /mnt"
  INSTALL_FORCE=1 run run_install --stage deploy propyl
  [ "$status" -eq 0 ]
  assert_call "nixos-install --flake .#propyl --root /mnt --no-root-passwd"
}

@test "deploy refuses a root mounted from tmpfs, which would build the closure into RAM" {
  printf '/mnt\n' >"$stubs/mounted_at"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  TMPFS=1 INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "deploy needs terraform first"
  assert_no_call "nixos-install"
}

# A host's fileSystems is the mount set the installed system reads at boot, so staging has to mount
# that same set. Creating @nix and leaving it unmounted means deploy writes the closure into @, and
# the boot mount of an empty @nix over /nix then hides it: /nix/store empty, stage 2's init missing,
# emergency.target. deploy names the gap instead of installing into it.
@test "deploy refuses a host whose declared tree mounts are not live under the install root" {
  printf '/ /boot /nix /home /var/log /var/cache /var/lib/swap /.snapshots\n' >"$stubs/mount_paths"
  # Only the root is mounted: the store would land inside @, and the tree stays empty.
  printf '/mnt /dev/vda2\n' >"$stubs/mounted_at"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "deploy refused"
  assert_out "/home"
  assert_out "/.snapshots"
  # The refusal comes before the prompt, so nothing installs.
  assert_no_call "nixos-install"
}

# A staging mount set equal to the host's mount set is the state deploy installs into: the closure
# lands in @nix and postdeploy's keys in @home, the same subvolumes boot reads.
@test "deploy accepts a root carrying every mount the host declares" {
  printf '/ /boot /nix /home /var/log /var/cache /var/lib/swap /.snapshots\n' >"$stubs/mount_paths"
  # The staging mount set the host declares: the root, the ESP, and every subvolume of the tree.
  printf '/mnt /dev/vda2\n/mnt/boot /dev/vda1\n' >"$stubs/mounted_at"
  for path in /nix /home /var/log /var/cache /var/lib/swap /.snapshots; do
    printf '/mnt%s /dev/vda2\n' "$path" >>"$stubs/mounted_at"
  done
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "nixos-install --flake .#methyl-nixos --root /mnt --no-root-passwd"
}

@test "deploy installs to the disk-backed mount and takes the caches with it" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "nixos-install --flake .#methyl-nixos --root /mnt --no-root-passwd"
  assert_call "--file modules/cache-registry.nix substituters"
  # The way into the system is postdeploy's job: an install writes the closure and the boot loader,
  # and never a key file or a password.
  assert_no_call "^chown"
  assert_no_call "^nixos-enter"
  assert_out "run --stage postdeploy"
}

@test "postdeploy hands the installer's ssh keys to the users the host declares" {
  printf '1\n' >"$stubs/mounted"
  mkdir -p "$stubs/home/.ssh"
  printf 'ssh-ed25519 AAAAtest josh@laptop\n' >"$stubs/home/.ssh/authorized_keys"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "^chown -R 1000:100" # uid:gid read from the installed system's own passwd
  grep -q 'ssh-ed25519 AAAAtest' "$stubs/root/mnt/home/josh/.ssh/authorized_keys"
  assert_no_call "nixos-install"
}

@test "postdeploy with no installer keys names the password step instead of blocking on it" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "^chown"
  # bats closes stdin, so the password is never asked for: the operator is told the exact command
  # that works against the freshly installed tree, which has no /run/current-system yet.
  assert_no_call "^nixos-enter"
  assert_out "nixos-enter --root /mnt -- passwd root"
  assert_out "nixos-enter --root /mnt -- passwd josh"
}

@test "postdeploy refuses when the host's config has no wheel user" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  ADMIN='' INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "no wheel user"
  assert_no_call "^passwd"
}

@test "postdeploy refuses while nothing disk-backed is mounted" {
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "postdeploy needs the installed root mounted"
  assert_no_call "^chown"
}

# INSTALL_PASSWORDS is the way in when there is no terminal to answer a prompt: the VM tier, and any
# scripted run. The stub nixos-enter emulates `chpasswd` by writing a hash into the fixture's shadow,
# so the test proves the effect and not just the call.
stub_chpasswd() {
  stub nixos-enter <<EOF
#!/usr/bin/env bash
echo "nixos-enter \$*" >> "$calls"
# emulates $(chpasswd): replaces the account's placeholder with a real hash
if [ "\${*: -1}" = chpasswd ]; then
  while IFS=: read -r u pw; do
    sed -i "s|^\$u:.*|\$u:\$6\$hash\$::|" "$stubs/root/mnt/etc/shadow"
  done
  exit 0
fi
exit \${NIXOS_ENTER_EXIT:-0}
EOF
}

@test "postdeploy with INSTALL_PASSWORDS sets root and the admin through chpasswd" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  stub_chpasswd
  INSTALL_PASSWORDS=$'root:toortest\njosh:testpass' INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "password set for root"
  assert_out "password set for josh"
  assert_call "^nixos-enter --root /mnt -- chpasswd$"
  assert_out_count "password set for" 2
}

# The value must never reach argv (the call log is on the host) or stdout (the serial log is on the
# host): it travels on stdin only.
@test "INSTALL_PASSWORDS never puts a password in the call log or the output" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  stub_chpasswd
  INSTALL_PASSWORDS=$'root:toortest\njosh:testpass' INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "toortest"
  assert_no_call "testpass"
  assert_no_out "toortest"
  assert_no_out "testpass"
}

# Only accounts the host declares may be given a password: an env file is operator input, not a
# licence to create access for someone the config never named.
@test "INSTALL_PASSWORDS refuses an account the host does not declare" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  stub_chpasswd
  INSTALL_PASSWORDS=$'root:toortest\nmallory:hunter2' INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "mallory"
  assert_no_call "^nixos-enter"
}

# The reboot guard reads the installed shadow, so a password supplied through the environment is
# what lets the run reach the boot step instead of stopping at "no password for root".
@test "passwords from INSTALL_PASSWORDS satisfy the reboot guard" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  stub_chpasswd
  INSTALL_PASSWORDS=$'root:toortest\njosh:testpass' INSTALL_FORCE=1 run run_install_in "$dir" --stage postdeploy,reboot methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_out "no password for"
  assert_call "^reboot"
}

@test "all stops at the first step nobody confirmed, so nothing installs" {
  printf '1\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(owned_recipe)")
  run run_install_in "$dir" methyl-nixos
  [ "$status" -eq 2 ]
  assert_no_call "nixos-install"
  assert_no_call "reboot"
}

@test "all with the override installs, writes keys and passwords, and reboots once root and an admin have passwords" {
  printf '0\n' >"$stubs/mounted"
  printf "root:\$6\$rounds\$abc::\njosh:\$6\$rounds\$abc::\n" >"$stubs/root/mnt/etc/shadow"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "./terraform.sh --force --recipe hosts/methyl-nixos/terraform.json"
  assert_call "^reboot"
}

@test "all refuses the reboot while the installed system has no password" {
  printf '0\n' >"$stubs/mounted"
  dir=$(recipe_repo methyl-nixos "$(uuid_recipe)")
  INSTALL_FORCE=1 run run_install_in "$dir" methyl-nixos
  [ "$status" -eq 2 ]
  assert_call "^nixos-install"
  assert_out "no password for root"
  assert_no_call "^reboot"
}
