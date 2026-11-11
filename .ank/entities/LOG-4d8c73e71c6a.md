---
id: LOG-4d8c73e71c6a
type: log
title: "Ceiling fixed: vm-run.sh now compares against cap+64 (VM_GATE_CEILING computed once), default"
created: 2026-11-11T00:40:51Z
author: josh@methyl-bazzite
scope:
  - tests/vm-run.sh
  - tests/vm-lib.bash
  - tests/vm-check.bats
about: TASK-3f3067de7a4b
seq: 1
schema: 4
version: 1
---

 VM_GATE_PEAK_SECONDS raised to 600, header prints cap and ceiling. Two suspects from the criterion, settled by evidence rather than guessed: (1) the plumbing suspect is disproven — vm-run.sh:92 samples qemu descended from the bats pid and tees its own peak_guest_mb into the gate log, and /var/mnt/data0/temp/flakeroot-tmp/logs/vm-gate-1794323540.log shows peak_guest_mb=1300 inside a green tier's TAP stream, so a green tier does feed the gate a peak; the 1311 the follow-up quoted came from the runner log, not the gate log. (2) the drive guest can never be sampled: vm_free_peak breaks after three blank polls once seen=1 (vm-lib.bash:254) and deploy runs minutes after the deploy guest exits, so VM_BOOT_CEILING is unreachable from the gate — recorded as a ponytail ceiling in vm-run.sh rather than a slack change. Regression test added to vm-check.bats (fake bats + fake getenforce on PATH, no boot), floor 14->16 in suite-ledger.txt; bash tests/floors.sh reports 16 and shellcheck -x is clean. bash tests/run.sh and the bats test itself need /dev/kvm, which this host lacks (SELinux Disabled, /dev/kvm absent) — the operator runs them.
