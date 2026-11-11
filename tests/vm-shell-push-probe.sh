#!/usr/bin/env bash
# Console probe for `tests/vm-shell.sh --push HOST`: the closure built on the host must reach the
# guest's disk-backed store and install onto the blank drive. It is typed, not injected, so it walks
# the same console a person would use. Markers are what the host greps for in its log; a missing
# marker is a failure even if qemu exited 0.
set -u

# shellcheck source=tests/vm-probe-lib.bash
source "$(dirname "$0")/vm-probe-lib.bash"

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

# 4. Registration. The closure arrived as a nar archive on /push-cache, and this guest copied it into
#    its own store, so the paths and their DB rows are real store content on the store disk —
#    `nix path-info` answering is the proof the closure is usable inside the guest rather than merely
#    visible on a share. The paths are this host's own unsigned build, so the signature check is the
#    client's to skip. `--import` of a raw export is not usable here: it buffers, and buffering 6.9 GiB
#    does not fit this guest's cap (see tests/vm-shell.sh).
start=$SECONDS
nix path-info "$path" >/dev/null ||
  nix copy --no-check-sigs --from "file:/push-cache" "$path" ||
  fail "closure did not register from /push-cache"
# fail() exits above, so reaching this line means the import succeeded; the span is what the wall-time
# baseline measures (.pi/PLAN-vm-pack-speed.md).
printf 'marker register rc=0 secs=%s\n' "$((SECONDS - start))"
nix path-info "$path" >/dev/null || fail "closure is not registered in the guest store"
ok "closure registered: $(nix path-info --recursive "$path" | wc -l) paths on $src"

# 5. The real deploy path, in two calls, because the UUID gate sits between them. install.sh builds
#    into its own scratch store, so that store goes on the disk too: a tmpfs scratch inside a 1GB
#    guest is the thing that overflows RAM — install_stage owns that scratch.
cd /repo || fail "cannot enter the repo share"
# The closure installed is the one this run booted: its fstab names the uuids the recipe declares, and
# terraform.sh formats the drive with exactly those, so the drive mounts its own closure (step 6).
INSTALL_SYSTEM="$path"
timed prepare install_stage prepare,terraform

# 6. The recipe the drive was built from, carrying the uuids it declared. A uuid names a filesystem,
#    so every mounted partition's uuid has to resolve on this drive: udev makes those links
#    asynchronously after mkfs, and they are the path fstab-by-uuid uses at boot.
recipe=/repo/hosts/methyl-test/terraform.json
mounted=$(jq -r '[.partitions[] | select(.mount != null)] | length' "$recipe")
[ "$mounted" -gt 0 ] || fail "the recipe mounts nothing"
jq -e '[.partitions[] | select(.mount != null) | .uuid] | all(. != null and . != "")' "$recipe" >/dev/null ||
  fail "the terraform stage left the recipe with no filesystem identities"
udevadm settle --timeout=15 || fail "udev never settled after the filesystems were created"
missing=0
for u in $(jq -r '.partitions[] | select(.mount != null) | .uuid' "$recipe"); do
  [ -e "/dev/disk/by-uuid/$u" ] || missing=$((missing + 1))
done
# A by-uuid link can be created after settle returns: check a second time before calling it a failure.
[ "$missing" = 0 ] || {
  udevadm settle --timeout=15 || fail "udev never settled after the filesystems were created"
  missing=0
  for u in $(jq -r '.partitions[] | select(.mount != null) | .uuid' "$recipe"); do
    [ -e "/dev/disk/by-uuid/$u" ] || missing=$((missing + 1))
  done
}
[ "$missing" = 0 ] || fail "$missing mounted partitions have no uuid path on the drive"
ok "recipe uuids resolve on the drive: $mounted mounted partitions, every uuid resolves under /dev/disk/by-uuid"

# Deploy is timed rather than guarded here: `timed` fails on a non-zero stage status and quotes the
# tail of the stage log, which is the same refusal a recipe whose mounts carry uuids would print.
timed deploy install_stage deploy
ok "deployed the pushed closure: $(jq -r '[.partitions[] | .uuid] | join(" ")' "$recipe")"

# 7. What the stages must have left on the drive: partitions, an ESP with boot entries, and the
#    closure. The table is proven by the partitions themselves — this guest's lsblk has no
#    PARTTABLENAME column, so asking for it reads as "no table" on a drive that has one.
[ -b /dev/vdb1 ] && [ -b /dev/vdb2 ] ||
  fail "the drive has no partitions after terraform: $(lsblk -o NAME /dev/vdb | tr '\n' ' ')"
entries=$(find /mnt/boot/loader/entries -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$entries" -gt 0 ] || fail "no systemd-boot entries on the ESP"
[ "$(find /mnt/nix/store -maxdepth 1 -type d 2>/dev/null | wc -l)" -gt 100 ] ||
  fail "the closure is not on the drive: $(find /mnt/nix/store -maxdepth 1 2>/dev/null | wc -l) entries"
ok "installed on the drive: $entries boot entries, $(find /mnt/nix/store -maxdepth 1 -type d | wc -l) store paths"

# 8. The way in. deploy leaves root locked, so the drive's login prompt is unanswerable until
#    postdeploy writes passwords into the installed tree. The fixture file is on this share; the
#    values reach chpasswd on stdin, never in argv and never in the transcript.
passwords=/repo/tests/vm-spike-secrets.env
[ -s "$passwords" ] || fail "no password fixture on the share: $passwords"
INSTALL_PASSWORDS=$(cat "$passwords")
export INSTALL_PASSWORDS
install_stage postdeploy || fail "postdeploy refused"
for u in root josh; do
  hash=$(grep "^$u:" /mnt/etc/shadow | cut -d: -f2)
  case "$hash" in
  '' | '!' | '!!' | '*') fail "$u holds no password in the installed shadow" ;;
  esac
done
ok "passwords written: root and josh hold hashes in the installed shadow"

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
  cp "$INSTALL_SYSTEM/kernel" /deploy-out/kernel || fail "no kernel in the installed closure"
  cp "$INSTALL_SYSTEM/initrd" /deploy-out/initrd || fail "no initrd in the installed closure"
  append=$(sed -e 's/[[:space:]]*regInfo=[^[:space:]]*//' -e '/^[[:space:]]*$/d' \
    "$INSTALL_SYSTEM/kernel-params" | tr '\n' ' ')
  [ -n "$append" ] || fail "the installed closure names no kernel parameters"
  printf '%s init=%s/init\n' "$append" "$INSTALL_SYSTEM" >"/deploy-out/append.txt"
  grep -q 'init=' "/deploy-out/append.txt" || fail "the boot append names no init"
  ok "boot files copied out: kernel, initrd, $(grep -o 'root=[^ ]*' "/deploy-out/append.txt")"
fi

# poweroff, not exit (see vm-probe-lib.bash): shutting the guest down ends the run immediately.
finish
