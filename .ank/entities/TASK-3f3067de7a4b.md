---
id: TASK-3f3067de7a4b
type: task
slug: the-vm-gate-judges-the-peak-it-actually-sampled
title: The VM gate judges the peak it actually sampled
created: 2026-11-11T00:16:10Z
author: josh@methyl-bazzite
status: done
scope:
  - tests/vm-run.sh
  - tests/vm-lib.bash
  - tests/vm-check.bats
blocked_by: []
done_criteria: |
  a non-booting bats test drives tests/vm-run.sh with a fake bats on PATH that prints peak_guest_mb=<cap+64> and exits 0, and the gate prints ok VM tier and exits 0; today the same fake makes it print FAIL over the ceiling. bash tests/run.sh green with tests/suite-ledger.txt carrying the raised vm-check.bats floor.
criteria_by: creator
method: diagnose
proof:
  - type: commit
    ref: 5cf2382
    criteria: f6acdd4d1e76
    via: submitted
schema: 4
version: 4
---

The gate compares observed -gt $cap (vm-run.sh:97) while the suite tolerates cap+64 (vm-check.bats:283), so a run whose every test passed can print FAIL over the ceiling. Two other suspects to settle before fixing: the gate greps peak_guest_mb from its own log, but the runners send the sampler output to their own logs (vm-shell.sh:262, :358), so a green tier may feed the gate no peak at all; and the gate samples any qemu-system, while the drive boot has its own ceiling (VM_BOOT_CEILING, vm-check.bats:320). Fix the shared root cause, not the arithmetic alone.
