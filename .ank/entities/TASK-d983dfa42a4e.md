---
id: TASK-d983dfa42a4e
type: task
slug: the-ghostty-build-carries-no-rewritten-appdir-pa
title: The Ghostty build carries no rewritten AppDir paths
created: 2026-11-04T17:01:56Z
author: josh@methyl-bazzite
status: done
scope:
  - features/hm-ghostty/_package.nix
  - tests/appdir.nix
blocked_by: []
done_criteria: |
  tests/appdir.nix plants the four upstream EKFs carriers in the fixture AppDir and asserts the built store path carries /tmp/EKFs= in exactly those paths, so a rewritten path in anything the installPhase itself writes, or in scaffolding it should have deleted, fails the build tier, and bash tests/run.sh stays green.
criteria_by: creator
method: diagnose
proof:
  - type: commit
    ref: 3e43d3f
    criteria: c00a03ec830b
    via: submitted
schema: 4
version: 3
---

features/hm-ghostty/_package.nix:26 records the limit: the AppDir's bundled libraries carry
build-time paths rewritten to /tmp/EKFs=, and the install phase relocates and symlinks around them.
appdir.nix proves which entries are kept, dropped and moved, but nothing checks what the relocated
tree actually references, so a ghostty that cannot find its bundled libs is a runtime failure on the
host rather than a gate failure.
