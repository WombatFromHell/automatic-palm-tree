#!/usr/bin/env bash
# Guest side of the VM spike. stdout reaches the host's serial log because the unit uses
# StandardOutput=journal+console. Marker lines are what the runner greps for; they are the
# assertion, so a missing marker is a failure even if qemu exited 0.
set -eu

fail() {
  echo "SPIKE FAIL: $1"
  exit 1
}
ok() { echo "SPIKE OK: $1"; }

# 1. The host packed the closure into the store image and the initrd registered it, so a
#    referenced path resolves with nothing fetched. Self-referential: this very script is in
#    virtualisation.additionalPaths.
self=""
for p in /nix/store/*-vm-spike.sh; do
  [ -e "$p" ] && self=$p && break
done
[ -n "$self" ] || fail "closure from the host did not land in the guest store"
ok "closure registered: $(basename "$self")"

# 2. Root is tmpfs, so nothing here survives the VM.
[ "$(findmnt -no FSTYPE /)" = tmpfs ] || fail "root is not tmpfs: $(findmnt -no FSTYPE /)"
ok "fresh root: tmpfs"

# 3. The writable store overlay accepts writes. `nix-store --add` rather than `nix store add-path`
# because the guest's nix has no experimental features enabled, and the point is the overlay, not
# the command surface.
[ -d /mnt/shared ] || fail "shared dir from the host is not mounted"
mkdir -p /mnt/shared/hello
echo spike >/mnt/shared/hello/f
added=$(nix-store --add /mnt/shared/hello) || fail "writable store refused"
[ -d "$added" ] || fail "added path did not land in /nix/store"
[ -d /nix/.ro-store ] || fail "read-only store image not mounted"
ok "writable store: $(basename "$added")"

# 4. The blank target drive the deploy stage will format.
[ -b /dev/vdb ] || fail "no blank target drive"
ok "target drive: $(lsblk -bno SIZE /dev/vdb) bytes"

# 5. Secrets arrive over the 9p share and are never printed. systemd credentials are not used here:
#    this guest kernel exposes no fw_cfg sysfs and qemu's SMBIOS type-11 string arrives empty.
cred=/mnt/shared/secrets.env
if [ ! -r "$cred" ]; then
  fail "secret file not delivered — share contents: $(find /mnt/shared -maxdepth 1 -printf '%f\n' 2>&1 | paste -sd, -)"
fi
grep -q '^root:' "$cred" || fail "secret file has no root entry"
ok "secret file delivered: $(wc -c <"$cred") bytes, contents not printed"

# 6. What the real stages need, present in the guest before any of them runs.
command -v nixos-install >/dev/null || fail "nixos-install missing"
bash -n /mnt/shared/terraform.sh || fail "terraform.sh not runnable"
ok "nixos-install present, terraform.sh parses"

# 7. The password path the installer's postdeploy will use: the secret file fed to chpasswd on
#    stdin only, so no secret reaches argv or the serial log. Comment lines are filtered the same
#    way install.sh filters them, because chpasswd reads every line as a user:pass pair.
#    This is what makes the serial login below possible.
lines=$(grep '^[A-Za-z0-9_-]*:' "$cred")
printf '%s\n' "$lines" | chpasswd || fail "chpasswd refused"
ok "passwords applied for: $(cut -d: -f1 <<<"$lines" | paste -sd, -)"

# No poweroff: the runner drives the serial login while the VM is alive, and its own timeout ends
# the run.
echo "SPIKE DONE"
