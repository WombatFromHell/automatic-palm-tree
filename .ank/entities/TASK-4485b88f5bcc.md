---
id: TASK-4485b88f5bcc
type: task
slug: the-gate-reports-each-tier-s-assertion-count-and
title: The gate reports each tier's assertion count and fails on a shortfall
created: 2026-11-07T21:50:38Z
author: josh@methyl-bazzite
status: open
scope:
  - tests/run.sh
  - tests/suite-ledger.txt
blocked_by: []
done_criteria: |-
  bash tests/run.sh exits 0 with every verdict line carrying its assertion count, and deleting one assertion from any suite turns the gate red.
criteria_by: creator
verify: [gate]
schema: 4
version: 1
---
Baseline floors, measured today: 301 bats tests, 536 assertions, 176 nix-unit attributes, 80 ck-tier checks. Today the gate prints 'ok <suite>' with no count, so a fixture refactor that loses an assertion is invisible. Floors live in tests/suite-ledger.txt and ratchet up only. Bound by ADR-5fc3d9cc7320.
