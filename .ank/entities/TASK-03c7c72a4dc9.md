---
id: TASK-03c7c72a4dc9
type: task
slug: run-the-root-deploy-contract-on-a-vm-not-by-hand
title: run the root deploy contract on a VM, not by hand
created: 2026-11-07T23:25:48Z
author: josh@methyl-bazzite
status: done
scope:
  - tests/deploy-loop.sh
blocked_by: []
done_criteria: |
  tests/deploy-loop.sh runs as root on a VM with a real loop device and reports every PASS line; the run is recorded as the task's proof.
criteria_by: creator
verify: [gate]
proof:
  - type: test
    ref: local/146a5d1da1fd@5badea4
    tree: scope/f6a3ac3259fd
    criteria: 96ef166f3907
    verifier: gate@dc484de6fdb9
    via: verifier
schema: 4
version: 3
---
