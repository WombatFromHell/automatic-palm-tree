---
id: LOG-cf9e5838c59d
type: log
title: "criterion froze as the literal '-': 'ank new task --criteria -' took '-' as the value, since only"
created: 2026-11-07T18:25:10Z
author: josh@methyl-bazzite
scope:
  - features/nixos-oom/**
  - tests/oomd.nix
  - tests/suite.nix
about: TASK-105ec823f249
seq: 1
schema: 4
version: 1
---

 --body reads stdin. release refused (illegal transition open -> open) while the claim is live, so the criterion stands unfixed and 'ank done' grades against the gate verifier, not against criterion prose. The criterion this task was actually held to: bash tests/run.sh exits 0 with tests/oomd.nix registered in tests/suite.nix and all its attributes green; features/nixos-oom/nixos.nix sets ManagedOOMSwap=kill on -.slice and user.slice, MemoryHigh/MemoryMax percentages on -.slice (null removes each), the pressure limit and duration on user.slice, no ManagedOOMPreference on user@, omit plus OOMScoreAdjust on display-manager, and defaults swapUsedLimit 75% / memPressureLimit 60% / memPressureDuration 15s / memoryHigh 93% / memoryMax 97%; a null swapUsedLimit keeps DefaultMemoryPressureDurationSec; no host file changed. A human can amend it once the claim ends.
