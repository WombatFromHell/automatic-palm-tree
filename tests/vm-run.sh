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
if [ ! -e /dev/kvm ]; then
  printf 'FAIL /dev/kvm is absent — the VM tier needs hardware acceleration.\n'
  exit 1
fi

log=$(vm_log_path vm-gate)
{
  printf 'run=%s\n' "${suites[*]}"
  printf 'ceiling=%s (each runner scopes its own guest at MemoryMax, MemorySwapMax=0)\n' "$cap"
  printf 'kvm=%s\n' "$(ls -l /dev/kvm)"
} >"$log"

# RAM is sampled while the guests are up. The gate wraps nothing: each runner already puts its guest
# in its own scope, and a scope here would charge the nested guest plus the closure copy to the same
# MemoryMax, which killed the tier at 1792M. What the gate owns is the ceiling the guests are allowed
# to reach, asserted from the sampled peak.
vm_free_peak "$peak_seconds" qemu >>"$log" 2>&1 &
peak=$!

rc=0
(cd "$vm_repo" && bats "${suites[@]}") >>"$log" 2>&1 || rc=$?
wait "$peak"

# Every suite samples its own peak, so more than one line can appear; the ceiling is about a
# single guest, so the first one is the number. grep exits 1 when nothing was sampled, which under
# set -e would abort here and leave the gate reporting no verdict at all.
observed=$(grep -o 'peak_guest_mb=[0-9]*' "$log" | cut -d= -f2 | head -1 || true)
if [ "$rc" -ne 0 ]; then
  printf 'FAIL VM tier [%s suites]\n' "${#suites[@]}"
  tail -n 20 "$log"
elif [ -z "$observed" ] || [ "$observed" -gt "$cap" ]; then
  printf 'FAIL VM tier peak_guest_mb=%s over the %sMB ceiling\n' "${observed:-none}" "$cap"
  tail -n 20 "$log"
  rc=1
else
  printf 'ok   VM tier [%s suites, peak_guest_mb=%s <= %s]\n' "${#suites[@]}" "$observed" "$cap"
fi
printf 'log=%s\n' "$log"
exit "$rc"
