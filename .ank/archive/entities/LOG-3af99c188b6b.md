---
id: LOG-3af99c188b6b
type: log
title: "VM_PUSH tier measured (logs/vm-shell-1794363753.log): pack compression=none secs=2 (was 173),"
created: 2026-11-11T02:33:31Z
author: josh@methyl-bazzite
scope:
  - tests/vm-run.sh
  - tests/vm-lib.bash
  - tests/vm-check.bats
about: TASK-3f3067de7a4b
seq: 6
schema: 4
version: 1
---

 register 80s, prepare 16s, deploy 69s, drive boot 12s; whole run 8:24 against 1m25s base. Closure bytes move 4x: pack->push-cache, 9p read->/dev/vdc, /dev/vdc->/dev/vdb. Candidate already measured by hand (logs/vm-shell-1794329465.log): drive_copy --to /mnt secs=87 with deploy secs=3 and deploy_copy_lines=0, i.e. 2 passes instead of 4, ~-65s per push test, at the cost of changing test 12's 'closure registered' marker and test 13's boot-file source. No code changed; questions for a fresh-context reviewer written to .pi/HANDOFF-vm-run.md.
