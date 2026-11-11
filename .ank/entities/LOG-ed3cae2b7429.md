---
id: LOG-ed3cae2b7429
type: log
title: "closed: criterion drifted: the 35 MiB/s pack was xz compression, which compression=none already"
created: 2026-11-11T07:13:28Z
author: josh@methyl-bazzite
scope:
  - tests/vm-shell.sh
about: TASK-1ca003ef65bf
seq: 1
schema: 4
version: 1
---

 removed (pack now 2–9 s vs the 173 s baseline); sharding was empirically rejected (push_rc=123) and has no span left to win — the pack-secs clause is met without the shard
