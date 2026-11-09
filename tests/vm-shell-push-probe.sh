#!/usr/bin/env bash
# Console probe for `tests/vm-shell.sh --push HOST`: the closure built on the host must reach the
# guest's disk-backed store and install onto the blank drive. It is typed, not injected, so it walks
# the same console a person would use. Markers are what the host greps for in its log; a missing
# marker is a failure even if qemu exited 0.
set -u

# fail exits, so a probe that reports a failure never reaches SHELL DONE, and the runner's marker
# loop is what catches it.
fail() {
  echo "SHELL FAIL: $1"
  exit 1
}
ok() { echo "SHELL OK: $1"; }

# 1. The raw store image, mounted where the writable store's upper half lives. A tmpfs here would
#    charge the guest's RAM for every path registered, which is the whole reason this disk exists.
src=$(findmnt -n -o SOURCE /nix/.rw-store)
[ "$src" = /dev/vdc ] || fail "store disk is $src, not /dev/vdc"
ok "store disk mounted: $src as $(findmnt -n -o FSTYPE /nix/.rw-store)"

# 2. The guest keeps its own closure read-only underneath, so its running system survives the push.
findmnt -n -o SOURCE /nix/store | grep -q overlay ||
  fail "/nix/store is $(findmnt -n -o SOURCE /nix/store), not an overlay"
ok "writable store layered on the read-only store image"

# 3. The closure the runner built on this host, handed over by the share rather than by the guest
#    config — naming a store path in the config would fail the derivation's reference check.
path=$(cat /repo/push-system)
case "$path" in
/nix/store/*) ;;
*) fail "push-system holds '$path', not a store path" ;;
esac
ok "closure handed over: $(basename "$path")"

# 4. Registration. The host pushed the closure into this guest's store over ssh, so the paths and
#    their DB rows are real store content on the store disk — `nix path-info` answering is the proof
#    the closure is usable inside the guest, not merely visible on a share.
nix path-info "$path" >/dev/null || fail "closure is not registered in the guest store — the host's ssh push failed"
ok "closure registered: $(nix path-info --recursive "$path" | wc -l) paths on $src"

# 5. The real deploy path, against the drive the runner left blank. install.sh builds into its own
#    scratch store, so that store goes on the disk too: a tmpfs scratch inside a 1GB guest is the
#    thing that overflows RAM.
mkdir -p /nix/.rw-store/scratch
chmod 755 /nix/.rw-store/scratch
cd /repo || fail "cannot enter the repo share"
INSTALL_SYSTEM="$path" INSTALL_DRIVE=/dev/vdb bash install.sh --force --scratch /nix/.rw-store/scratch \
  --stage prepare,terraform,deploy methyl-test || fail "install stages failed"

# 6. What the stages must have left on the drive: a table, an ESP with boot entries, and the closure.
[ -n "$(lsblk -no PARTTABLENAME /dev/vdb)" ] || fail "the drive carries no partition table after terraform"
entries=$(find /mnt/boot/loader/entries -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$entries" -gt 0 ] || fail "no systemd-boot entries on the ESP"
[ "$(find /mnt/nix/store -maxdepth 1 -type d 2>/dev/null | wc -l)" -gt 100 ] ||
  fail "the closure is not on the drive: $(find /mnt/nix/store -maxdepth 1 2>/dev/null | wc -l) entries"
ok "installed on the drive: $entries boot entries, $(find /mnt/nix/store -maxdepth 1 -type d | wc -l) store paths"

# 7. The boot files for --boot. The host cannot read a file out of a qcow2 without root, so the
#    installed kernel and initrd are copied out through the writable share. The installed config's
#    kernel parameters carry the init path but no root device — the ESP entries that would normally
#    supply it are not what boots here — and regInfo names a closure-info path that is not in the
#    installed store, so it is dropped.
if [ -d /deploy-out ]; then
  cp "$path/kernel" /deploy-out/kernel || fail "no kernel in the installed closure"
  initrd=$(find /nix/store -maxdepth 2 -name initrd -type f 2>/dev/null | head -1)
  [ -n "$initrd" ] || fail "no initrd among the installed store paths"
  cp "$initrd" /deploy-out/initrd || fail "could not copy the initrd out"
  root=$(findmnt -n -o SOURCE /mnt)
  sed 's/ *regInfo=[^ ]*//' "$path/kernel-params" >"/deploy-out/append.txt"
  printf ' root=%s\n' "$root" >>"/deploy-out/append.txt"
  ok "boot files copied out: kernel, $(basename "$initrd"), root=$root"
fi

# poweroff, not exit: a shell that merely exits gets its getty respawned, and qemu then sits idle on
# an open console until the runner's timeout.
echo "SHELL DONE"
poweroff
