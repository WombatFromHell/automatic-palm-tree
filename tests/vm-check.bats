#!/usr/bin/env bats
# The VM harness against a real boot: memory capped in a scope, guest state fresh every run, log on
# the host that called it. This is the slow tier — it boots a guest and needs /dev/kvm plus SELinux
# permissive — so it runs through its own gate, tests/vm-run.sh, and never inside tests/run.sh
# (TEST_DESIGN.md's guide rule, .pi/PLAN-vm-e2e.md).
load helpers

setup() {
  repo="$PWD"
  [ -e /dev/kvm ] || skip "no /dev/kvm — the VM tier needs hardware acceleration"
  [ "$(getenforce 2>/dev/null || echo absent)" = Permissive ] ||
    skip "SELinux is not permissive — qemu cannot open its /dev/shm share"
}

# The VM gate (tests/vm-run.sh) owns this tier, and it must refuse rather than skip when the host
# cannot run qemu. Cheap: a stub getenforce, no boot.
@test "the VM gate refuses to run where SELinux is enforcing" {
  local stub="$BATS_TMPDIR/vm-stub-$$"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nprintf "Enforcing\n"\n' >"$stub/getenforce"
  chmod +x "$stub/getenforce"
  run env PATH="$stub:/usr/bin:/bin" bash "$repo/tests/vm-run.sh"
  rm -rf "$stub"
  [ "$status" -eq 1 ]
  assert_out "selinux=Enforcing"
}

# The human-facing harness, driven the way a person drives it: commands typed into the console,
# markers read back from the host's log. S2's proof is that the guest can see what the stages need.
@test "the interactive harness boots a guest that sees the repo, the stage tools and a blank drive" {
  local run_root=${VM_TMP:-/var/mnt/data0/temp/flakeroot-tmp}
  local before
  before=$(find "$run_root" -maxdepth 1 -name 'vm-shell-*' -type d | wc -l)

  run bash "$repo/tests/vm-shell.sh" --script "$repo/tests/vm-shell-probe.sh"
  [ "$status" -eq 0 ]

  local log
  log=$(grep -o '^log=.*' <<<"$output" | cut -d= -f2)
  [ -f "$log" ]
  for marker in 'SHELL OK: repo visible' 'SHELL OK: stage tools present' \
    'SHELL OK: target drive blank' 'SHELL OK: drive named: /dev/vdb' \
    'SHELL OK: secret file delivered' 'SHELL DONE'; do
    grep -q "$marker" "$log"
  done

  local peak
  peak=$(grep -o 'peak_guest_mb=[0-9]*' "$log" | cut -d= -f2)
  [ "$peak" -le 1300 ]

  # Nothing carries over: the run dir is gone, so the next invocation starts empty.
  [ "$(find "$run_root" -maxdepth 1 -name 'vm-shell-*' -type d | wc -l)" -eq "$before" ]

  # The probe reads the secret file but never prints it, so the host's log holds no password.
  run grep -q 'toortest' "$log"
  [ "$status" -ne 0 ]
}

@test "the spike boots fresh, stays inside its cap, leaves nothing behind, and logs on this host" {
  local run_root=${VM_TMP:-/var/mnt/data0/temp/flakeroot-tmp}
  local before
  before=$(find "$run_root" -maxdepth 1 -name 'vm-spike-*' -type d | wc -l)

  run bash "$repo/tests/vm-spike-run.sh"
  [ "$status" -eq 0 ]

  # Requirement 4: the run drops a log on the machine that called it, and names it in its output.
  local log
  log=$(grep -o '^log=.*' <<<"$output" | cut -d= -f2)
  [ -f "$log" ]
  grep -q 'SPIKE=ok login=ok' "$log"

  # Requirement 3: the guest never exceeds the scope's cap, which is what protects this host.
  local peak
  peak=$(grep -o 'peak_guest_mb=[0-9]*' "$log" | cut -d= -f2)
  [ "$peak" -le 1300 ]

  # Requirement 1: nothing carries over. The run dir is deleted, so the next run starts empty.
  [ "$(find "$run_root" -maxdepth 1 -name 'vm-spike-*' -type d | wc -l)" -eq "$before" ]

  # The password is typed by the harness and never echoed by the guest, so it must not be in a log
  # the host keeps.
  run grep -q 'toortest' "$log"
  [ "$status" -ne 0 ]
}
