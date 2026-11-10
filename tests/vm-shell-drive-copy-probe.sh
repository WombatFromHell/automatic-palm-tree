#!/usr/bin/env bash
# Console probe for the question `tests/vm-shell-push-probe.sh` leaves open: can a packed archive be
# copied straight onto the DRIVE's store, and does `nixos-install` then skip its own copy? Both are
# store semantics a host proxy cannot reproduce — a 9p share as the source and a mounted drive as the
# target store — so this runs inside the guest and is run by hand (SELinux must be Permissive):
#
#   sudo setenforce 0
#   time VM_TMP=/var/mnt/data0/temp/flakeroot-tmp \
#     tests/vm-shell.sh --push methyl-test --script "$(pwd)/tests/vm-shell-drive-copy-probe.sh"
#   sudo setenforce 1
#
# It measures; it changes nothing in install.sh. The closure installed here is the run's *initial*
# one, whose fstab names methyl-test's real drive uuids, so the drive is installed but deliberately
# not booted — hence no `--boot`. A drive that boots is already proven by test 10 of vm-check.bats.
#
# Every stage prints a `marker <name> rc=.. secs=..` line, so the wall times land on the console
# while each stage's own output stays in a per-stage log the markers quote on failure.
set -u

# shellcheck source=tests/vm-probe-lib.bash
source "$(dirname "$0")/vm-probe-lib.bash"

# One timed stage: the stage's output goes to its own log, and `time`'s real/user/sys lines go there
# too, so the console carries only the marker.
timed() {
  local label=$1
  shift
  local stage_log="/tmp/drive-probe-$label.log" start=$SECONDS rc=0
  { time "$@" >>"$stage_log" 2>&1; } 2>>"$stage_log" || rc=$?
  # The command rides in the marker line rather than in a separate banner: the banner lines did not
  # reach the serial console in the run that proved this, while marker lines always did.
  printf 'marker %s rc=%s secs=%s cmd=%s\n' "$label" "$rc" "$((SECONDS - start))" "$*"
  [ "$rc" = 0 ] || fail "$label failed: $(tail -c 300 "$stage_log")"
}

# 1. The drive formatted and mounted by the real terraform stage. The target store has to be the
#    filesystem a host would actually boot from, not a scratch directory.
cd /repo || fail "cannot enter the repo share"
timed terraform install_stage prepare,terraform
findmnt -n -o TARGET /mnt >/dev/null || fail "/mnt is not mounted after the terraform stage"
ok "drive staged: $(findmnt -n -o SOURCE /mnt) as $(findmnt -n -o FSTYPE /mnt)"

path=$(cat /repo/push-system)
case "$path" in
/nix/store/*) ;;
*) fail "push-system holds '$path', not a store path" ;;
esac

# 2. Archive -> drive store, with no guest-store unpack in between. This is the copy install.sh
#    currently performs through /nix/.rw-store; doing it against the drive is the candidate.
#    `file:` is read-only in practice here, and nothing writes into /push-cache.
before=$(find /mnt/nix/store -maxdepth 1 -type d 2>/dev/null | wc -l)
timed drive_copy nix copy --no-check-sigs --from "file:/push-cache" --to /mnt "$path"
nix path-info --store /mnt "$path" >/dev/null || fail "the closure is not valid in the drive store"
after=$(find /mnt/nix/store -maxdepth 1 -type d | wc -l)
printf 'marker drive_store_paths before=%s after=%s size_mb=%s\n' \
  "$before" "$after" "$(du -m -s /mnt/nix/store | cut -f1)"
[ "$after" -gt 100 ] || fail "only $after paths landed in the drive store"
ok "drive store accepts the archive: $after paths registered under /mnt/nix/store"

# 3. Deploy against a drive store that already holds the closure. `nixos-install` copies the system
#    path into the target store when it is not valid there; a store that already carries it should
#    write no copies at all. The count is the whole measurement.
INSTALL_SYSTEM="$path"
timed deploy install_stage deploy
copies=$(grep -c 'copying path' /tmp/drive-probe-deploy.log 2>/dev/null || true)
entries=$(find /mnt/boot/loader/entries -maxdepth 1 -type f 2>/dev/null | wc -l)
printf 'marker deploy_copy_lines=%s boot_entries=%s drive_store_paths=%s\n' \
  "$copies" "$entries" "$(find /mnt/nix/store -maxdepth 1 -type d | wc -l)"
[ "$entries" -gt 0 ] || fail "deploy wrote no boot entries: $(tail -c 300 /tmp/drive-probe-deploy.log)"
ok "deploy: $copies 'copying path' lines, $entries boot entries on the ESP"

# poweroff, not exit (see vm-probe-lib.bash): shutting the guest down ends the run immediately.
finish
