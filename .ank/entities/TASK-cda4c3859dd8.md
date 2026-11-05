---
id: TASK-cda4c3859dd8
type: task
slug: delete-the-tests-red-tier-and-bring-the-gate-doc
title: Delete the tests/red tier and bring the gate documents back to what run.sh does
created: 2026-11-05T02:31:52Z
author: nix-unit-suite
status: done
scope:
  - tests/red
  - tests/run.sh
  - TEST_DESIGN.md
blocked_by: [TASK-97a9e3eadea3]
done_criteria: |
  bash tests/run.sh exits 0 and ank check reports no fault.
criteria_by: creator
verify: [gate]
proof:
  - type: test
    ref: local/010a5baf8cad@fe09f85
    tree: scope/770ba436fed6
    criteria: a31b02a100b4
    verifier: gate@dc484de6fdb9
    via: verifier
schema: 4
version: 2
---

PLAN-suite-audit.md step 3, PLAN-nix-unit.md S4. The stale numbers: TEST_DESIGN.md claims the largest per-eval peak is 921MB (home.nix) and fixture builds cost 8/5/4/10s; measured now 965MB and 0/2/1/1s on a warm store.

ck/suite stay: configs.nix, home.nix, mounts.nix and wrap.nix are still ck/suite-shaped, so deleting the helpers here breaks four suites. Their migration is a separate decision, not this task.

ADR-dcf30409fc01 keeps the old rule accepted; once tests/red/ is deleted its tests/red/*.nix scope matches nothing and ank review reports the scope gone dead, which is the retirement path. Ratification of ADR-fb331caa521d is a human act and comes after this lands.
