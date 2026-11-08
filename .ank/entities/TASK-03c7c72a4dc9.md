---
id: TASK-03c7c72a4dc9
type: task
slug: run-the-root-deploy-contract-on-a-vm-not-by-hand
title: run the root deploy contract on a VM, not by hand
created: 2026-11-07T23:25:48Z
author: josh@methyl-bazzite
status: open
scope:
  - tests/deploy-loop.sh
blocked_by: []
done_criteria: |
  tests/deploy-loop.sh runs as root on a VM with a real loop device and reports every PASS line; the run is recorded as the task's proof.
criteria_by: creator
verify: [gate]
schema: 4
version: 1
---
