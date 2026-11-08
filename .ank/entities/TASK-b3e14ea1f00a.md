---
id: TASK-b3e14ea1f00a
type: task
slug: a-vacuous-suite-a-swallowed-sfdisk-failure-and-a
title: A vacuous suite, a swallowed sfdisk failure and a skipped CI tier all go red
created: 2026-11-07T21:50:49Z
author: josh@methyl-bazzite
status: done
scope:
  - tests/disk-fixture.bash
  - tests/support.nix
  - tests/run.sh
blocked_by: [TASK-4485b88f5bcc]
done_criteria: |-
  bash tests/run.sh exits 0, and each of the three guards has a test that fails before it exists: entries_json on an image with no partition table, suite "x" [], and a tier whose tool is missing while CI is set.
criteria_by: creator
verify: [gate]
proof:
  - type: test
    ref: local/566570acbc05@957188a
    tree: scope/3c646857feda
    criteria: 11753baaba92
    verifier: gate@dc484de6fdb9
    via: verifier
schema: 4
version: 3
---
Three ways the gate goes green with nothing proven: entries_json swallows sfdisk failure so a wiped GPT compares equal to itself (disk-fixture.bash:135, terraform.bats:255); a ck-tier suite with checks == [] prints OK (support.nix:189), while suite.nix has tripwires for the same thing; a missing nix-unit or bats prints skip and exits 0 (run.sh:124, :240), leaving 176 attributes and 301 tests unrun. Bound by ADR-5fc3d9cc7320 and the vacuous-pass rule of ADR-fb331caa521d.
