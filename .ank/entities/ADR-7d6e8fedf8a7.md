---
id: ADR-7d6e8fedf8a7
type: adr
slug: the-test-gate-is-eval-only-and-memory-capped
title: The test gate is eval-only and memory-capped
created: 2026-11-04T16:49:27Z
author: josh@methyl-bazzite
status: accepted
scope:
  - tests/run.sh
  - tests/nix-eval.sh
  - tests/**/*.nix
constraint: |
  Every suite runs through tests/nix-eval.sh inside a transient systemd scope (TEST_MEMORY_MAX_MB, default 1792), prints OK <suite>, and builds nothing except the appdir, shellwrap and yazi-install fixtures; tests/configs.nix evaluates one host per process because forcing three hosts needs about 4GB.
ratified: ee3cad75ffdf
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

A suite that balloons is killed inside the scope instead of swapping the machine, and the scope's
peak memory is printed on the same line as the verdict so the cap is auditable. One host's config
costs about 1.4GB of anonymous memory, hence the per-host configs loop.

Tests build feature packages through tests/support.nix's pkgsSet — the loader's own set, keyed by
system, with pinMeta, flakePackages and pkgs.unstable — so a suite cannot drift from production.
Bash-level behaviour (installer flags, switch command, trusted-user gate, argv, exit codes) is bats
against PATH stubs, ~0MB, not eval.
