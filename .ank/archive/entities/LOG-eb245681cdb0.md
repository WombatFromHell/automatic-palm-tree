---
id: LOG-eb245681cdb0
type: log
title: "Clauses 1-4 of this criterion are proved without booting anything: bats tests/vm-check.bats is 15"
created: 2026-11-11T06:17:19Z
author: josh@methyl-bazzite
scope:
  - tests/vm-run.sh
  - tests/vm-check.bats
about: TASK-088204af2c00
seq: 2
schema: 4
version: 1
---

 ok / 2 skip / rc 0 on this host (VM_PUSH unset). vm-run.sh:61 raises the headroom floor to vm_headroom_push=2500 under VM_PUSH=1; vm-run.sh:113-138 runs the single --push --boot before bats and exits 1 when the run prints no log= line, otherwise exports VM_PUSH_LOG; vm-check.bats:303-304 and :357-358 skip without VM_PUSH_LOG and read log=$VM_PUSH_LOG only. .push-handoff and shared_push_run exist nowhere under tests/. Note the criterion says 'tests 13 and 14' but the two push tests are now 14 and 15 — the two new stub tests shifted the numbering; the clause is met in substance. Clause 5 awaits the operator: ank done runs vmgate itself (VM_PUSH=1 bash tests/vm-run.sh), and headroom here is ram=3184 swap=3974 with systemd degraded, so the boot waits for healthier headroom.
