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
    'SHELL OK: store disk mounted: /dev/vdc' \
    'SHELL OK: sshd listening, authorized key installed' \
    'SHELL OK: secret file delivered' 'SHELL DONE'; do
    grep -q "$marker" "$log"
  done

  # ssh is on by default, so the runner proves the forwarded port answers from this host before it
  # types anything: a guest that cannot be ssh'd into is not a machine a person can drive.
  assert_out 'ssh=ok'

  local peak
  peak=$(grep -o 'peak_guest_mb=[0-9]*' "$log" | cut -d= -f2)
  [ "$peak" -le 1300 ]

  # Nothing carries over: the run dir is gone, so the next invocation starts empty.
  [ "$(find "$run_root" -maxdepth 1 -name 'vm-shell-*' -type d | wc -l)" -eq "$before" ]

  # The probe reads the secret file but never prints it, so the host's log holds no password.
  run grep -q 'toortest' "$log"
  [ "$status" -ne 0 ]
}

# A probe that fails must end the run, not sit at a respawned login prompt until the boot timeout:
# that idle is what makes a failing run look like a hung one. The probe exits, so only SHELL FAIL
# can end it, and the runner must report a failure rather than a clean exit.
@test "a probe that fails ends the run instead of idling to the boot timeout" {
  local started elapsed log
  started=$SECONDS
  run bash "$repo/tests/vm-shell.sh" --script "$repo/tests/vm-shell-failing-probe.sh"
  elapsed=$((SECONDS - started))

  [ "$status" -ne 0 ]
  [ "$elapsed" -lt 120 ]

  log=$(grep -o '^log=.*' <<<"$output" | cut -d= -f2)
  [ -f "$log" ]
  grep -q 'SHELL FAIL' "$log"
}

# --boot names a drive that only --push's deploy writes, so it must refuse on the host before a
# guest boots — an idle guest waiting on a boot timeout is not an answer to a bad flag.
@test "--boot without --push refuses before anything boots" {
  run bash "$repo/tests/vm-shell.sh" --boot
  [ "$status" -ne 0 ]
  assert_out '--boot needs --push HOST'
}

# A push run naming a host this flake has no config for must fail on the host, before a guest boots:
# the build is the part that can tell, and booting a guest to find out costs a minute. Cheap — an
# eval failure, no VM.
@test "--push refuses a host with no closure before anything boots" {
  run bash "$repo/tests/vm-shell.sh" --push definitely-not-a-host
  [ "$status" -ne 0 ]
  assert_out 'no closure for host definitely-not-a-host'
}

# The deploy flow against a closure the guest did not build: the host builds it, pushes it into the
# guest's store over ssh, and the guest installs it onto the blank drive. It copies gigabytes, so it
# is opt-in rather than part of every VM gate run.
@test "--push installs a host closure onto the drive from the guest" {
  [ "${VM_PUSH:-0}" = 1 ] || skip "VM_PUSH unset — this copies a host closure into the guest"

  local run_root=${VM_TMP:-/var/mnt/data0/temp/flakeroot-tmp}
  local before
  before=$(find "$run_root" -maxdepth 1 -name 'vm-shell-*' -type d | wc -l)

  run bash "$repo/tests/vm-shell.sh" --push methyl-test --script "$repo/tests/vm-shell-push-probe.sh"
  [ "$status" -eq 0 ]

  local log
  log=$(grep -o '^log=.*' <<<"$output" | cut -d= -f2)
  [ -f "$log" ]
  for marker in 'SHELL OK: store disk mounted: /dev/vdc' \
    'SHELL OK: writable store layered on the read-only store image' \
    'SHELL OK: closure handed over' \
    'SHELL OK: closure registered' \
    'SHELL OK: mounted uuids resolve' \
    'SHELL OK: recorded into the share and deployed' \
    'SHELL OK: installed on the drive' 'SHELL DONE'; do
    grep -q "$marker" "$log"
  done

  # The closure reached the guest by push, not by eval: the host built it and streamed it over ssh,
  # so a guest with 1GB of RAM never runs a host closure build. push_rc is the runner's own result.
  grep -q '^push=/nix/store/' "$log"
  grep -q '^push_rc=0' "$log"

  # A blank drive cannot carry the UUIDs the real host's recipe recorded, so the run's copy of the
  # recipe drops them — mkfs is never given a UUID.
  grep -q '^push_recipe=.* uuids=stripped' "$log"

  # The point of the store disk: gigabytes of registration must cost disk, not the guest's RAM. The
  # bound is the cap this run printed, not a hand-copied number — a memcg can overshoot its
  # memory.max by a few MB of kernel accounting before reclaim fires (measured here: 1304 against a
  # 1300M cap), so the slack is headroom for that overshoot, not room for a tmpfs store: a tmpfs
  # would cost gigabytes, which is what this assertion is there to catch.
  local cap peak
  cap=$(grep -o 'MemoryMax=[0-9]*M' "$log" | head -1 | cut -d= -f2 | tr -d M)
  peak=$(grep -o 'peak_guest_mb=[0-9]*' "$log" | cut -d= -f2)
  [ "$peak" -le "$((cap + 64))" ]

  # Nothing carries over: the store image and the pushed closure die with the run dir.
  [ "$(find "$run_root" -maxdepth 1 -name 'vm-shell-*' -type d | wc -l)" -eq "$before" ]
}

# The installed drive boots. A reboot inside the deploy guest would re-run the tmpfs config, so the
# drive is booted by a second qemu from the kernel and initrd the probe copied out of it (D7), and the
# proof is a login prompt answered by the installed system's own password.
@test "--push HOST --boot boots the installed drive to its login prompt" {
  [ "${VM_PUSH:-0}" = 1 ] || skip "VM_PUSH unset — this builds, copies and then boots twice"

  run bash "$repo/tests/vm-shell.sh" --push methyl-test --boot --script "$repo/tests/vm-shell-push-probe.sh"
  [ "$status" -eq 0 ]

  local log
  log=$(grep -o '^log=.*' <<<"$output" | cut -d= -f2)
  [ -f "$log" ]
  # The boot files come from the installed closure. root=fstab makes systemd read this drive's uuids
  # out of its own fstab; init=<path> is what stage-1 reads to find the closure it is booting.
  grep -q '^disk_boot=.*empty0.qcow2 append=.*root=fstab' "$log"
  grep -q '^disk_boot=.*append=.*init=/nix/store/' "$log"
  grep -q '^rebuild=' "$log"
  grep -q 'SHELL OK: recorded into the share, rebuilt, and deployed' "$log"
  grep -q 'BOOT OK: installed generation reached its login prompt' "$log"

  # A drive that fails to mount its own uuids drops to emergency mode, which prints no login prompt:
  # that is the defect this test exists to catch, so emergency must not appear in the drive's region.
  run grep -q 'Reached target Emergency Mode' "$log"
  [ "$status" -ne 0 ]

  # The prompt is the installed system's own, and it only starts after multi-user is reached. The
  # password is never typed here: deploy leaves root locked until postdeploy sets one.
  grep -q 'methyl-test login:' "$log"

  # Both boots stayed inside their caps: 1300M for the deploy guest, VM_BOOT_CEILING for the drive.
  [ "$(grep -c 'peak_guest_mb=' "$log")" -eq 2 ]
  [ "$(grep -o 'peak_guest_mb=[0-9]*' "$log" | tail -1 | cut -d= -f2)" -le "${VM_BOOT_CEILING:-2000}" ]
}

# VM_SHELL_BIND publishes the forwarded port beyond loopback. The guest is scratch, so this is opt-in;
# what it must prove is that a published port still answers, and that the run names an address a
# machine on the LAN could actually use.
@test "VM_SHELL_BIND publishes the ssh port on every interface" {
  run env VM_SHELL_BIND=0.0.0.0 bash "$repo/tests/vm-shell.sh" --script "$repo/tests/vm-shell-probe.sh"
  [ "$status" -eq 0 ]

  assert_out "ssh=ok"
  local line
  line=$(grep -o 'ssh: .*' <<<"$output" | head -1)
  case "$line" in *"vm@0.0.0.0"* | *"vm@127.0.0.1"*) false ;; esac # names a real address, not the bind
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
