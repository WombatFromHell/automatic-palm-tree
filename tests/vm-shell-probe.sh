#!/usr/bin/env bash
# Console probe the scripted smoke types into the interactive guest (tests/vm-shell.sh --script).
# It is typed, not injected, so it exercises the same console a person would use. Marker lines are
# what the host greps in its log: a missing marker is a failure even if qemu exited 0. Nothing here
# runs a stage — S2 proves the guest can see what the stages need.
set -u

# fail exits, so a probe that reports a failure never reaches SHELL DONE, and the runner's marker
# loop is what catches it.
fail() {
  echo "SHELL FAIL: $1"
  exit 1
}
ok() { echo "SHELL OK: $1"; }

# 1. The repo the installer will run from, delivered over the 9p share.
[ -f /mnt/repo/flake.nix ] || fail "repo share not mounted: $(find /mnt/repo -maxdepth 1 2>&1 | head -3)"
ok "repo visible: $(find /mnt/repo -maxdepth 1 -type f | wc -l) files at the top level"

# 2. Every tool the real stages invoke, resolved before any of them is asked for.
for tool in nix nixos-install terraform jq sfdisk mkfs.btrfs mkfs.vfat; do
  command -v "$tool" >/dev/null || fail "$tool missing"
done
ok "stage tools present"

# 3. The blank target drive, and nothing on it yet.
[ -b /dev/vdb ] || fail "no target drive"
[ -z "$(lsblk -no PARTTABLENAME /dev/vdb)" ] || fail "target drive already carries a table"
ok "target drive blank: $(lsblk -bno SIZE /dev/vdb) bytes"

# 4. The drive name install.sh reads, so install.sh never has to guess one.
[ "$INSTALL_DRIVE" = /dev/vdb ] || fail "INSTALL_DRIVE is '$INSTALL_DRIVE', not /dev/vdb"
ok "drive named: $INSTALL_DRIVE"

# 5. The secret file came with the repo share, and the probe never prints its contents.
cred=/mnt/repo/tests/vm-spike-secrets.env
grep -q '^[A-Za-z0-9_-]*:' "$cred" || fail "secret file has no user:pass entry"
ok "secret file delivered: $(wc -c <"$cred") bytes, contents not printed"

# poweroff, not exit: a shell that merely exits gets its getty respawned, and qemu then sits idle
# on an open console until the runner's timeout. Shutting the guest down ends the run immediately.
echo "SHELL DONE"
poweroff
