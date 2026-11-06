---
id: TASK-c78a9688a6bc
type: task
slug: exercise-pin-meta-s-per-system-boundary-for-a-se
title: Exercise pin-meta's per-system boundary for a second architecture
created: 2026-11-04T17:01:56Z
author: josh@methyl-bazzite
status: done
scope:
  - lib/pin-meta.nix
  - tests/pins.nix
blocked_by: []
done_criteria: |
  a fixture metadata.json that declares aarch64-linux in arches with no hash throws pinnedSystems' message naming that system, and one that pins hashes without declaring arches throws the other branch; tests/pins.nix stays green.
criteria_by: creator
method: tdd
proof:
  - type: commit
    ref: 56caf6a
    criteria: 2487260ca631
    via: submitted
schema: 4
version: 3
---

TEST_DESIGN names the gap: every host is x86_64-linux, so pin-meta's per-system boundaries are never
exercised. Both throw branches in pinnedSystems exist and neither has ever run, so an arches/hashes
mismatch in a new pin is untested code that a newcomer would read as working.

Fixtures, not real pins: this repo ships one architecture, so the boundary has to be proven with a
metadata.json that no host consumes.
