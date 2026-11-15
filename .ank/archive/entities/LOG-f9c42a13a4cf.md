---
id: LOG-f9c42a13a4cf
type: log
title: "Two follow-on conclusions from this run, for the tasks that are blocked on it. TASK-1ca0: the tree"
created: 2026-11-11T06:39:02Z
author: josh@methyl-bazzite
scope:
  - tests/vm-shell.sh
  - tests/vm-run.sh
about: TASK-c5f48738a9b5
seq: 2
schema: 4
version: 1
---

 packs with one recursive nix copy --no-check-sigs --to file://$push_cache?compression=none (tests/vm-shell.sh:166), measured push_rc=0 secs=2 against the 173 s xz baseline — the 35 MiB/s was compression, not one thread's hashing, so sharding has no span left to win and that criterion should be closed with this finding rather than implemented. TASK-acd3: msize 262144 (tests/vm-shell.sh:253) measured register secs=78 against the 75 s it replaced, so registration was not msize-bound; 1048576 stays unmeasured and its RAM cost trades against a 1300M guest peaking at 1304.
