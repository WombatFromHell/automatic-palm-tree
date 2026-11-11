---
id: TASK-1ca003ef65bf
type: task
slug: the-pack-is-sharded-across-host-cores
title: The pack is sharded across host cores
created: 2026-11-11T00:16:30Z
author: josh@methyl-bazzite
status: closed
scope:
  - tests/vm-shell.sh
blocked_by: [TASK-c5f48738a9b5]
done_criteria: |
  tests/vm-shell.sh packs the closure with the path list sharded over nix copy --no-check-sigs, keeps push_rc=0 and push_cache=new in the log, and a --push --boot run still prints closure handed over, closure registered, recipe uuids resolve on the drive and deployed the pushed closure; its pack secs are under the baseline pack secs.
criteria_by: creator
schema: 4
version: 2
---

One nix copy is single-threaded (per-path hash, verify, narinfo) and is the 35 MiB/s. The host has 16 free cores and the pack runs outside the guest scope, so sharding costs no guest RAM. Unverified: the ~30s estimate, and whether nix-store -qR emits every path the registration needs. Profile one sharded pack before trusting either.
