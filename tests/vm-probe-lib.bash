#!/usr/bin/env bash
# The guest side of the VM tier. Probes are typed into the serial console by tests/vm-shell.sh and read
# this file over the /repo 9p share, so it holds no host commands — systemd-run and qemu live in
# tests/vm-lib.bash, and a guest cannot run either.
#
# This is the only place the console protocol exists. tests/vm-shell.sh ends a scripted run when it sees
# SHELL DONE or SHELL FAIL, and tests/vm-check.bats greps SHELL OK markers out of the host log, so a
# probe that rewords its own output is a run that idles to the boot timeout. Tests/vm-check.bats pins
# these strings without booting anything.

ok() { printf 'SHELL OK: %s\n' "$1"; }

fail() {
  printf 'SHELL FAIL: %s\n' "$1"
  exit 1
}

# poweroff, not exit: a getty respawns on the console forever once the script exits, so exiting leaves
# qemu idle until the runner's boot timeout runs out.
finish() {
  printf 'SHELL DONE\n'
  poweroff
}

# The installer contract every probe shares. zram stays off because install.sh's prepare stage sizes its
# tmpfs and zram against RAM the systemd scope caps, and a guest ceiling far below methyl-test's own
# would be swapped out by that sizing; the scratch lives under /nix/.rw-store/scratch, packed fresh in
# this run; /dev/vdb is the store disk the guest was booted with.
#
# PROBE_SCRATCH is the only difference from a guest run — tests/vm-check.bats points it at a directory
# it can write, since /nix is not writable outside the guest. The host name is fixed: every probe in
# this tier is the methyl-test fixture.
install_stage() {
  local scratch="${PROBE_SCRATCH:-/nix/.rw-store/scratch}"
  # Created here rather than at the call sites, and 755 because the guest's own boot script may have
  # made it owned by someone other than the user install.sh runs as.
  mkdir -p "$scratch" && chmod 755 "$scratch"
  local env=(INSTALL_ZRAM=0 INSTALL_DRIVE=/dev/vdb)
  # The stages that install a closure carry it in INSTALL_SYSTEM; prepare runs before any closure exists.
  [ -n "${INSTALL_SYSTEM:-}" ] && env+=("INSTALL_SYSTEM=$INSTALL_SYSTEM")
  env "${env[@]}" bash install.sh --force --scratch "$scratch" --stage "$1" methyl-test
}
