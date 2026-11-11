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
# RAM is a precondition too (vm_headroom_check): a tier on a host where RAM and swap are both nearly
# full makes systemd-oomd kill the largest holder under user.slice, which is not the guest.
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
# The slack the suite itself allows (tests/vm-check.bats: a memcg overshoots memory.max by a few MB
# before reclaim fires). Both sides must tolerate the same overshoot, or a run whose every test passed
# fails the gate on the last line it prints.
ceiling=$((cap + 64))
# Long enough to survive the pack: `nix build` runs before any qemu exists, so a window shorter than
# the pack ends sampling before the deploy guest ever boots and the verdict judges nothing.
# ponytail: one sampler, one number. vm_free_peak reads whichever qemu pgrep finds at each poll and
# prints the largest value it saw (vm-lib.bash:239-265), and it breaks after three blank polls once
# it has seen a guest (:254) — so the drive guest, which boots only after the deploy guest is gone,
# is never sampled here. Measured: the gate reported 1300, the deploy guest's peak, while the drive
# guest peaked at 1167. Safe only while the drive guest stays under this ceiling: it is scoped at
# VM_BOOT_CEILING (2000M), so a drive guest between cap+64 and that cap would fail the verdict on a
# suite whose every test passed. Judging each guest against its own cap is a design change,
# see .pi/PLAN-vm-gate-verdict.md.
peak_seconds="${VM_GATE_PEAK_SECONDS:-600}"

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
# --push runs a host pack scope plus a 1GB guest, so it needs vm-shell.sh's own threshold, and the
# gate checks it here so a refusal inside the push cannot hide behind a test skip.
headroom=$((cap + 1024))
if [ "${VM_PUSH:-0}" = 1 ] && [ "$headroom" -lt "$vm_headroom_push" ]; then headroom="$vm_headroom_push"; fi
vm_headroom_check "$headroom" || exit 1

log=$(vm_log_path vm-gate)
# The preconditions and the log path go to the terminal as well as the log: the path up front is the
# thing you can `tail -f` while a run takes minutes. Everything this gate prints goes through vm_say,
# so the tty stream and the log say the same thing.
{
  printf 'run=%s\n' "${suites[*]}"
  printf 'ceiling=%s (cap %s plus the 64MB the suite tolerates; each runner scopes its own guest at MemoryMax, MemorySwapMax=0)\n' "$ceiling" "$cap"
  printf 'kvm=%s\n' "$(ls -l /dev/kvm)"
  printf 'log=%s\n' "$log"
} | tee -a "$log"

# RAM is sampled while the guests are up. The gate wraps nothing: each runner already puts its guest in
# its own scope, and a scope here would charge the nested guest plus the closure copy to the same
# MemoryMax, which killed the tier at 1792M. What the gate owns is the ceiling the guests are allowed
# to reach, asserted from the sampled peak — and the verdict takes the largest peak line in the log,
# so one sampler per phase covers every guest: the push run predates bats, so the sampler that wraps
# bats cannot see it.
# Ctrl+C has to end the run, not just the gate. bats ignores SIGINT and keeps starting suites after
# the gate is gone, and a guest lives in a systemd scope that no tty signal can reach, so the gate
# kills whatever is running (ending the push or the suites) and every vm-* scope still live (ending
# whatever is booted). The runners' own watchers cover the case where a runner dies without the gate
# asking.
push_pid=""
push_peak=""
push_out=""
bats_pid=""
peak=""
# shellcheck disable=SC2329  # invoked by the trap below, never by name
interrupted() {
  # kill with an empty argument kills nothing at all, so each pid is guarded: an interrupt during the
  # push run must reach the push, and one during bats must reach bats.
  local p
  for p in "$push_pid" "$push_peak" "$bats_pid" "$peak"; do
    [ -n "$p" ] && kill -TERM "$p" 2>/dev/null || true
  done
  # systemd's own mechanism, not a signal: a guest lives in a scope no tty signal can reach.
  vm_stop_all
  if [ -n "$push_out" ]; then rm -f "$push_out"; fi
  vm_say "interrupted — log=$log"
  exit 130
}
trap interrupted INT TERM

# Bats runs each test in its own process, so nothing in the file can carry a run from one test to
# the next: the gate owns the one --push --boot run that serves both push tests, and hands the
# completed run to them through VM_PUSH_LOG. They then only assert against that log, and a failed
# run still fails each of them on its own missing markers. vm-shell.sh prints its log path on stdout
# on every failure after the headroom check, and the threshold above closes the only refusal that
# precedes it, so a dead push is a gate failure here, not a test skip.
if [ "${VM_PUSH:-0}" = 1 ]; then
  vm_say "push: one --push --boot guest; the push tests assert against its log"
  push_out="$vm_tmp/push-out.$$"
  bash "$repo/tests/vm-shell.sh" --push methyl-test --boot --script "$repo/tests/vm-shell-push-probe.sh" >"$push_out" 2>&1 &
  push_pid=$!
  # Alive signal is the push run itself, so this sampler ends with the push instead of burning the
  # whole window waiting for guests that have not started yet.
  vm_free_peak "$peak_seconds" qemu-system "$push_pid" | tee -a "$log" &
  push_peak=$!
  # The push's own exit status is not the verdict: a run that printed its log but failed is judged by
  # the two push tests, which fail on its missing markers and fail the tier.
  wait "$push_pid" || true
  wait "$push_peak" || true
  # pipefail + set -e turns a no-match grep into a failed assignment, which would abort the gate here
  # and exit 1 with no reason printed — the same trap the sampler guards its first poll against.
  push_log=$(grep -o '^log=.*' "$push_out" | tail -1 | cut -d= -f2 || true)
  if [ -z "$push_log" ]; then
    vm_say "FAIL push run ended before printing its log: $(tail -n 2 "$push_out" | tr '\n' ' ')"
    rm -f "$push_out"
    push_out=""
    exit 1
  fi
  rm -f "$push_out"
  push_out=""
  export VM_PUSH_LOG="$push_log"
  vm_say "push log=$push_log"
fi

# tee, not a redirect: the gate is the thing a person waits on, so the suite's own output (bats TAP,
# plus the runners' boot/ssh/log lines) shows as it happens. pipefail keeps the suite's exit code on
# the pipeline, and bash's wait on a background pipeline reports that pipeline status.
(cd "$vm_repo" && bats "${suites[@]}") 2>&1 | tee -a "$log" &
bats_pid=$!

# tee is the pipeline's last process, so it exits exactly when bats closes stdout: that is the
# sampler's alive signal, and a tier whose suites never show qemu (skipped, or no VM_PUSH fixtures)
# would otherwise burn its whole VM_GATE_PEAK_SECONDS window after bats finished.
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
elif [ -z "$observed" ] || [ "$observed" -gt "$ceiling" ]; then
  vm_say "FAIL VM tier peak_guest_mb=${observed:-none} over the ${ceiling}MB ceiling"
  tail -n 20 "$log" | tee -a "$log"
  rc=1
else
  vm_say "ok   VM tier [${#suites[@]} suites, peak_guest_mb=$observed <= $ceiling]"
fi
vm_say "log=$log"
exit "$rc"
