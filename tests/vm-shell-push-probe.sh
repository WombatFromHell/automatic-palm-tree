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

# 5. The real deploy path, in two calls, because the UUID gate sits between them. install.sh builds
#    into its own scratch store, so that store goes on the disk too: a tmpfs scratch inside a 1GB
#    guest is the thing that overflows RAM.
mkdir -p /nix/.rw-store/scratch
chmod 755 /nix/.rw-store/scratch
cd /repo || fail "cannot enter the repo share"
# The closure installed is the one whose fstab names THIS drive's uuids, so it is rebuilt from the
# folded recipe rather than the checked-in one (see step 8). Before the fold it is the host's.
install_system="$path"
stage() {
  INSTALL_SYSTEM="$install_system" INSTALL_DRIVE=/dev/vdb bash install.sh --force \
    --scratch /nix/.rw-store/scratch --stage "$1" methyl-test
}
stage prepare,terraform || fail "install stages failed"

# 6. The record: the UUIDs the drive actually carries, written next to the install root. A UUID names
#    a filesystem that already exists, so every mounted partition's uuid must resolve on this drive.
record=/mnt/terraform.json
[ -f "$record" ] || fail "terraform stage left no recorded recipe at $record"
mounted=$(jq -r '[.partitions[] | select(.mount != null)] | length' "$record")
# udev makes /dev/disk/by-uuid links asynchronously after mkfs, and this is the path fstab-by-uuid
# will use at boot, so settle the queue rather than trusting the link to be there already.
udevadm settle --timeout=15 || fail "udev never settled after the filesystems were created"
missing=0
for u in $(jq -r '.partitions[] | select(.mount != null) | .uuid // "none"' "$record"); do
  [ "$u" = none ] || [ -e "/dev/disk/by-uuid/$u" ] || missing=$((missing + 1))
done
[ "$missing" = 0 ] || fail "$missing mounted partitions have no uuid path on the drive"
[ "$mounted" -gt 0 ] || fail "the recorded recipe mounts nothing"
ok "recorded recipe: $mounted mounted partitions, every uuid resolves under /dev/disk/by-uuid"

# 7. Deploy refuses before nixos-install while the recipe names labels only. This costs nothing: the
#    gate is a read, and it fires before any write.
out=$(stage deploy 2>&1) && fail "deploy accepted a recipe that declares no UUID"
case "$out" in
*declares\ no\ filesystem\ UUID*)
  ok "deploy refused the uuid-free recipe"
  ;;
*)
  fail "deploy failed for a different reason: $(printf '%s\n' "$out" | tail -3)"
  ;;
esac

# 8. The fold, into the share this run installed from. The repo file on this host is untouched: these
#    uuids name a scratch drive, not methyl-test's real one.
cp "$record" /repo/hosts/methyl-test/terraform.json || fail "could not fold the recorded recipe"

# The closure built on this host names methyl-test's real drive in its fstab; the scratch drive here
# carries the uuids just recorded. A boot that mounts by uuid cannot resolve those, so the host
# rebuilds the closure from the folded recipe in the share and pushes it back before deploy runs.
if [ -d /deploy-out ]; then
  touch /deploy-out/rebuild-request
  for _ in $(seq 90); do
    [ -s /deploy-out/rebuilt-system ] && break
    [ -s /deploy-out/rebuild-failed ] && fail "host rebuild: $(cat /deploy-out/rebuild-failed)"
    sleep 1
  done
  [ -s /deploy-out/rebuilt-system ] || fail "no rebuilt closure within 90s"
  install_system=$(cat /deploy-out/rebuilt-system)
  nix path-info "$install_system" >/dev/null || fail "rebuilt closure is not in the guest store"
fi
stage deploy || fail "deploy refused after the fold"
ok "folded into the share, rebuilt, and deployed: $(jq -r '[.partitions[] | .uuid] | join(" ")' /repo/hosts/methyl-test/terraform.json)"

# 9. What the stages must have left on the drive: a table, an ESP with boot entries, and the closure.
# 9. What the stages must have left on the drive: partitions, an ESP with boot entries, and the
#    closure. The table is proven by the partitions themselves — this guest's lsblk has no
#    PARTTABLENAME column, so asking for it reads as "no table" on a drive that has one.
[ -b /dev/vdb1 ] && [ -b /dev/vdb2 ] ||
  fail "the drive has no partitions after terraform: $(lsblk -o NAME /dev/vdb | tr '\n' ' ')"
entries=$(find /mnt/boot/loader/entries -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$entries" -gt 0 ] || fail "no systemd-boot entries on the ESP"
[ "$(find /mnt/nix/store -maxdepth 1 -type d 2>/dev/null | wc -l)" -gt 100 ] ||
  fail "the closure is not on the drive: $(find /mnt/nix/store -maxdepth 1 2>/dev/null | wc -l) entries"
ok "installed on the drive: $entries boot entries, $(find /mnt/nix/store -maxdepth 1 -type d | wc -l) store paths"

# 10. The boot files for --boot. The host cannot read a file out of a qcow2 without root, so the
#    installed kernel and initrd are copied out through the writable share. The installed config's
#    kernel parameters carry the init path but no root device — the ESP entries that would normally
#    supply it are not what boots here — and regInfo names a closure-info path that is not in the
#    installed store, so it is dropped.
# 10. The boot files for --boot, from the closure that was installed: the running VM's initrd carries
#     the payload's fstab (label nix-store, /dev/vdc, the 9p shares), and booting that against the
#     drive times out on devices the drive does not have. stage-1 names the closure with init=<path>
#     on the kernel command line (initrd-find-nixos-closure-start reads init=, not regInfo=), and the
#     closure's own kernel-params file names no init, so it is added here; root=fstab stays, because
#     the installed fstab is what names this drive's uuids.
if [ -d /deploy-out ]; then
  cp "$install_system/kernel" /deploy-out/kernel || fail "no kernel in the installed closure"
  cp "$install_system/initrd" /deploy-out/initrd || fail "no initrd in the installed closure"
  append=$(sed -e 's/[[:space:]]*regInfo=[^[:space:]]*//' -e '/^[[:space:]]*$/d' \
    "$install_system/kernel-params" | tr '\n' ' ')
  [ -n "$append" ] || fail "the installed closure names no kernel parameters"
  printf '%s init=%s/init\n' "$append" "$install_system" >"/deploy-out/append.txt"
  grep -q 'init=' "/deploy-out/append.txt" || fail "the boot append names no init"
  ok "boot files copied out: kernel, initrd, $(grep -o 'root=[^ ]*' "/deploy-out/append.txt")"
fi

# poweroff, not exit: a shell that merely exits gets its getty respawned, and qemu then sits idle on
# an open console until the runner's timeout.
echo "SHELL DONE"
poweroff
