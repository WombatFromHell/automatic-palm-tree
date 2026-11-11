---
id: LOG-2a78df168e5f
type: log
title: "bats mechanism verified from source: each @test runs in a fresh bats-exec-test bash process (set"
created: 2026-11-11T05:23:34Z
author: josh@methyl-bazzite
scope:
  - tests/vm-check.bats
  - tests/vm-lib.bash
  - tests/vm-run.sh
about: TASK-9b026f16c85d
seq: 2
schema: 4
version: 1
---

 -eET, re-sources the .bats file), setup_file runs in bats-exec-file's process, only exported env crosses the boundary — so the file-scope push_log cache can never carry; .pi/HANDOFF-vm-run-bats.md carries the full handoff for the co-agent reviewer. Handoff fix hit a scope trap (vm_tmp unset in the .bats file — file uses ${VM_TMP:-default}). Verification run found a second defect: the probe's uuid check flaked (1 missing by-uuid link after udevadm settle; retry landed), and its 'Killed' line is the runner's own vm_kill_scope cleanup, not OOM. Run-scoping gap: when test 13 fails, test 14's own run becomes the handoff for the next run.
