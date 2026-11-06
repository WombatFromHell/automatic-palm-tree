#!/usr/bin/env bats
# install.sh against PATH stubs: which stage runs, what it confirms, what it refuses. No root, no
# real disk, no eval. The destructive contract is the point: nothing reaches the drive until the
# operator says yes to that one step, and prepare must leave the partition table byte-identical.
load helpers

setup() {
  harness_stub_dir
  printf 'true\n' >"$stubs/owned"
  printf '/dev/vda\n' >"$stubs/device"
  printf 'disk\n' >"$stubs/disk_type"
  printf '0\n' >"$stubs/mounted"
  printf 'table\n' >"$stubs/table"
  printf '0\n' >"$stubs/dd_calls"
  # The shared-drive path reads the mounts the host declares instead of a disko device.
  printf '/dev/disk/by-label/nixos\n' >"$stubs/root_device"
  printf 'ext4\n' >"$stubs/root_fs"
  printf '/dev/disk/by-label/boot\n' >"$stubs/esp_device"

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
# The disko script is built into the scratch store, so the fake lands where install.sh looks for it.
if [ -n "\$store" ]; then
  mkdir -p "\$store/nix/store/fake/bin"
  printf '#!/usr/bin/env bash\necho "disko \$*" >> "%s"\nif [ "\${DISKO_EXIT:-0}" != 1 ]; then echo 1 > "%s/mounted"; fi\nexit \${DISKO_EXIT:-0}\n' "$calls" "$stubs" >"\$store/nix/store/fake/bin/disko"
  chmod +x "\$store/nix/store/fake/bin/disko"
fi
case "\$args" in
  *ownsWholeDisk*)          cat "$stubs/owned" ;;
  *disko.devices.disk*)     cat "$stubs/device" ;;
  *fileSystems*)            printf '%s\n%s\n%s\n' "\$(cat "$stubs/root_device")" "\$(cat "$stubs/root_fs")" "\$(cat "$stubs/esp_device")" ;;
  *osUsernames*)            printf 'josh\n' ;;
  *adminUsernames*)         printf '%s\n' "\${ADMIN-josh}" ;;
  *system.build.diskoScript*) printf '/nix/store/fake\n' ;;
  *substituters*)           printf 'https://cache.example/x\n' ;;
  *trustedPublicKeys*)      printf 'cache.example:2\n' ;;
  *) exit 1 ;;
esac
EOF

  stub lsblk <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$calls"
# /dev/zram0 is absent unless the suite says it is there, so the zram branch is deterministic.
case "\$*" in
  */dev/zram0*) printf '%s\n' "\${ZRAM:-}" ;;
  *PKNAME*) printf 'vda\n' ;;
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
  stub findmnt <<EOF
#!/usr/bin/env bash
echo "findmnt \$*" >> "$calls"
case "\$*" in *scratch*) exit 1 ;; esac
if [ "\$(cat "$stubs/mounted")" = 1 ] || grep -q '^mount /dev' "$calls"; then echo "/dev/vda2"; exit 0; fi
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
  *) t="" ;;
esac
if [ -n "\$t" ]; then printf '%s\n' "\$t"; exit 0; fi
exit 2
EOF

  # terraform.sh reads the table through jq; stubbing it keeps the suite off whatever jq this
  # machine happens to have.
  stub jq <<EOF
#!/usr/bin/env bash
echo "jq \$*" >> "$calls"
printf '/dev/vda1 C12A7EA9-344C-4175-A575-202976385741\n/dev/vda2 0FC63DAF-8483-4772-8E79-3D69D8457574\n'
EOF

  # Formatting is the destructive step: it is logged, never performed.
  for tool in mkfs.vfat mkfs.ext4 mkfs.btrfs; do
    stub "$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$calls"
exit \${MKFS_EXIT:-0}
EOF
  done

  # The scratch store is a tmpfs mount attempt; stubbing it keeps the suite off the real mount.
  stub mount <<EOF
#!/usr/bin/env bash
echo "mount \$*" >> "$calls"
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
  assert_no_call "disko --mode"
  assert_no_call "nixos-install"
  assert_no_call "mkswap"
}

@test "prepare accepts a shared drive and never asks disko for a device" {
  printf 'false\n' >"$stubs/owned"
  run run_install --dry-run --stage prepare methyl
  [ "$status" -eq 0 ]
  assert_out "shares /dev/vda"
  assert_call "fileSystems"
  assert_no_call "disko.devices.disk"
  assert_out "partition table unchanged"
}

@test "prepare refuses a device that is not a whole disk" {
  printf 'part\n' >"$stubs/disk_type"
  run run_install --dry-run --stage prepare methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "not a whole disk"
}

@test "a drive that already has partitions is still a whole drive" {
  # lsblk lists the disk and every partition it holds, so the check must look at the disk line
  # only: an installed drive is exactly the case terraform is supposed to adopt.
  printf 'disk\npart\npart\n' >"$stubs/disk_type"
  INSTALL_FORCE=1 run run_install --stage terraform methyl-nixos
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

@test "deploy adds zram before the build starts when RAM is short" {
  printf '1\n' >"$stubs/mounted"
  INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  # The build is what overflows the ISO's RAM, so the swap device has to exist before it, not after.
  [ "$(grep -n '^swapon /dev/zram0' "$calls" | cut -d: -f1)" -lt "$(grep -n '^nixos-install' "$calls" | cut -d: -f1)" ]
}

@test "deploy leaves an existing zram device alone" {
  printf '1\n' >"$stubs/mounted"
  ZRAM=zram INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "^swapon"
  assert_no_call "^mkswap"
}

@test "terraform refuses to wipe without a confirmation" {
  run run_install --stage terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "everything currently on it is destroyed"
  assert_no_call "disko --mode"
}

@test "terraform wipes once, with the three modes, and never the wipe-all flag" {
  INSTALL_FORCE=1 run run_install --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "disko --mode create,format,mount"
  assert_call "mount -t tmpfs -o size=2G"
  assert_no_call "yes-wipe"
  assert_no_call "destroy"
  assert_call "findmnt .* /mnt/nix"
}

@test "terraform adopts an existing layout instead of rebuilding it" {
  printf '1\n' >"$stubs/mounted"
  INSTALL_FORCE=1 run run_install --stage terraform methyl-nixos
  [ "$status" -eq 0 ]
  assert_out "adopted, not rebuilt"
  assert_call "disko --mode mount"
}

@test "terraform on a shared drive runs terraform.sh and never disko" {
  printf 'false\n' >"$stubs/owned"
  run run_install --dry-run --stage terraform methyl
  [ "$status" -eq 0 ]
  assert_out "[dry-run] ./terraform.sh --dry-run --disk /dev/vda --mount /mnt --root-fs ext4"
  assert_no_call "disko --mode"
  assert_no_call "mkfs"
}

@test "terraform on a shared drive adopts the signed partitions and mounts the declared root" {
  printf 'false\n' >"$stubs/owned"
  INSTALL_FORCE=1 run run_install --stage terraform methyl
  [ "$status" -eq 0 ]
  # Both partitions carry a signature, so nothing is formatted and only the root is mounted.
  assert_no_call "mkfs"
  assert_call "^mount /dev/vda2 /mnt$"
  assert_no_call "disko --mode"
  assert_out "mounted from the partitions methyl declares"
}

@test "terraform on a shared drive refuses to format a blank partition with nobody to ask" {
  printf 'false\n' >"$stubs/owned"
  ROOT_TYPE= run run_install --stage terraform methyl
  [ "$status" -eq 2 ]
  assert_out "needs a confirmation and there is no terminal"
  assert_no_call "mkfs"
  assert_no_call "^mount /dev"
}

@test "terraform on a shared drive refuses a blank partition the host names by UUID" {
  printf 'false\n' >"$stubs/owned"
  printf '/dev/disk/by-uuid/1234\n' >"$stubs/root_device"
  ROOT_TYPE= run run_install --stage terraform methyl
  [ "$status" -eq 2 ]
  assert_out "UUID"
  assert_no_call "^mount /dev"
}

@test "terraform fails when the target store never got mounted" {
  INSTALL_FORCE=1 DISKO_EXIT=1 run run_install --stage terraform methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "did not leave a disk-backed /mnt/nix"
}

@test "deploy refuses before terraform" {
  INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "deploy needs terraform first"
  assert_no_call "nixos-install"
}

@test "deploy installs to the disk-backed mount and takes the caches with it" {
  printf '1\n' >"$stubs/mounted"
  INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "nixos-install --flake .#methyl-nixos --root /mnt --no-root-passwd"
  assert_call "--file modules/cache-registry.nix substituters"
}

@test "deploy hands the installer's ssh keys to the users the host declares" {
  printf '1\n' >"$stubs/mounted"
  mkdir -p "$stubs/home/.ssh"
  printf 'ssh-ed25519 AAAAtest josh@laptop\n' >"$stubs/home/.ssh/authorized_keys"
  INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "^chown -R 1000:100" # uid:gid read from the installed system's own passwd
  grep -q 'ssh-ed25519 AAAAtest' "$stubs/root/mnt/home/josh/.ssh/authorized_keys"
}

@test "deploy with no installer keys installs anyway and names the password step" {
  printf '1\n' >"$stubs/mounted"
  INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 0 ]
  assert_no_call "^chown"
  # bats closes stdin, so the password is never asked for: the operator is told the exact command
  # that works against the freshly installed tree, which has no /run/current-system yet.
  assert_no_call "^nixos-enter"
  assert_out "nixos-enter --root /mnt -- passwd root"
  assert_out "nixos-enter --root /mnt -- passwd josh"
}

@test "deploy refuses when the host's config has no wheel user" {
  printf '1\n' >"$stubs/mounted"
  ADMIN='' INSTALL_FORCE=1 run run_install --stage deploy methyl-nixos
  [ "$status" -eq 2 ]
  assert_out "no wheel user"
  assert_no_call "^passwd"
}

@test "all stops at the first step nobody confirmed, so nothing installs" {
  printf '1\n' >"$stubs/mounted"
  run run_install methyl-nixos
  [ "$status" -eq 2 ]
  assert_no_call "nixos-install"
  assert_no_call "reboot"
}

@test "all with the override installs and reboots once root and an admin have passwords" {
  printf '0\n' >"$stubs/mounted"
  printf "root:\$6\$rounds\$abc::\njosh:\$6\$rounds\$abc::\n" >"$stubs/root/mnt/etc/shadow"
  INSTALL_FORCE=1 run run_install methyl-nixos
  [ "$status" -eq 0 ]
  assert_call "disko --mode create,format,mount"
  assert_call "^reboot"
}

@test "all refuses the reboot while the installed system has no password" {
  printf '0\n' >"$stubs/mounted"
  INSTALL_FORCE=1 run run_install methyl-nixos
  [ "$status" -eq 2 ]
  assert_call "^nixos-install"
  assert_out "no password for root"
  assert_no_call "^reboot"
}
