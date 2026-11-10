#!/usr/bin/env bash
# The VM gate. Separate from tests/run.sh on purpose (TEST_DESIGN.md's guide rule): run.sh is
# eval-and-stub and runs anywhere, while every suite here boots a real qemu guest, needs /dev/kvm,
# needs SELinux permissive, and costs minutes plus a gigabyte. Nothing under tests/vm-* may appear in
# run.sh's suite list -- run.sh refuses it.
#
# Preconditions are host facts, so they fail loudly here instead of skipping: a VM tier that silently
# skips proves nothing. Run it with:
#
#   sudo setenforce 0        # SELinux permissive, needed for unprivileged qemu to open its share
#   bash tests/vm-run.sh
#   sudo setenforce 1        # restore afterwards
#
#   bash tests/vm-run.sh stop  # end a tier running elsewhere: systemd stops the scopes, then the
#                              # scratch dirs whose owner is gone are removed
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/vm-lib.bash
source "$repo/tests/vm-lib.bash"

# The suites this gate owns. Adding one here is the only way a VM suite gets run; run.sh rejects the
# name outright.
suites=(tests/vm-check.bats)
# Cap per guest, and the ceiling the gate asserts the sampled peak stayed under.
# Suites may lower it per boot (tests/vm-spike-run.sh boots at 1300M).
cap="${VM_GATE_MEM:-1300}"
peak_seconds="${VM_GATE_PEAK_SECONDS:-300}"

vm_selinux_check || exit 1
if [ "${1:-}" = stop ]; then
  # Teardown is not a test, so it needs no kvm and no permissive SELinux: it only ends scopes this
  # tier owns and clears the scratch dirs whose owner is gone.
  vm_stop_all
  exit 0
fi
if [ ! -e /dev/kvm ]; then
  printf 'FAIL /dev/kvm is absent — the VM tier needs hardware acceleration.\n'
  exit 1
fi

log=$(vm_log_path vm-gate)
# The preconditions and the log path go to the terminal as well as the log: the path up front is the
# thing you can `tail -f` while a run takes minutes. Everything this gate prints goes through vm_say,
# so the tty stream and the log say the same thing.
{
  printf 'run=%s\n' "${suites[*]}"
  printf 'ceiling=%s (each runner scopes its own guest at MemoryMax, MemorySwapMax=0)\n' "$cap"
  printf 'kvm=%s\n' "$(ls -l /dev/kvm)"
  printf 'log=%s\n' "$log"
} | tee -a "$log"

# RAM is sampled while the guests are up. The gate wraps nothing: each runner already puts its guest
# in its own scope, and a scope here would charge the nested guest plus the closure copy to the same
# MemoryMax, which killed the tier at 1792M. What the gate owns is the ceiling the guests are allowed
# to reach, asserted from the sampled peak.
# Ctrl+C has to end the run, not just the gate. bats ignores SIGINT and keeps starting suites after
# the gate is gone, and a guest lives in a systemd scope that no tty signal can reach, so the gate
# kills bats (ending the suites) and every vm-* scope still live (ending whatever is booted). The
# runners' own watchers cover the case where a runner dies without the gate asking.
bats_pid=""
peak=""
# shellcheck disable=SC2329  # invoked by the trap below, never by name
interrupted() {
  kill -TERM "$bats_pid" "$peak" 2>/dev/null || true
  # systemd's own mechanism, not a signal: a guest lives in a scope no tty signal can reach.
  vm_stop_all
  vm_say "interrupted — log=$log"
  exit 130
}
trap interrupted INT TERM

# tee, not a redirect: the gate is the thing a person waits on, so the suite's own output (bats TAP,
# plus the runners' boot/ssh/log lines) shows as it happens. pipefail keeps the suite's exit code on
# the pipeline, and bash's wait on a background pipeline reports that pipeline status.
(cd "$vm_repo" && bats "${suites[@]}") 2>&1 | tee -a "$log" &
bats_pid=$!

# The suites are the sampler's alive signal: a tier whose suites never show qemu (skipped, or no
# VM_PUSH fixtures) would otherwise burn its whole VM_GATE_PEAK_SECONDS window after bats finished.
# tee is the pipeline's last process, so it exits exactly when bats closes stdout.
vm_free_peak "$peak_seconds" qemu-system "$bats_pid" | tee -a "$log" &
peak=$!

rc=0
wait "$bats_pid" || rc=$?
# A sampler that dies is a missing measurement, not a failed run: the verdict below reports the
# missing peak instead of the gate exiting with the sampler's status and printing nothing.
wait "$peak" || true

# Every suite samples its own peak, so more than one line can appear; the ceiling is per guest, so
# the largest sample is the number. grep exits 1 when nothing was sampled, which under set -e would
# abort here and leave the gate reporting no verdict at all.
observed=$(grep -o 'peak_guest_mb=[0-9]*' "$log" | cut -d= -f2 | sort -n | tail -1 || true)
if [ "$rc" -ne 0 ]; then
  vm_say "FAIL VM tier [${#suites[@]} suites]"
  tail -n 20 "$log" | tee -a "$log"
elif [ -z "$observed" ] || [ "$observed" -gt "$cap" ]; then
  vm_say "FAIL VM tier peak_guest_mb=${observed:-none} over the ${cap}MB ceiling"
  tail -n 20 "$log" | tee -a "$log"
  rc=1
else
  vm_say "ok   VM tier [${#suites[@]} suites, peak_guest_mb=$observed <= $cap]"
fi
vm_say "log=$log"
exit "$rc"
