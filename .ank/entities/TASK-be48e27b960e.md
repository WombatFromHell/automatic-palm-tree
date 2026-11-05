---
id: TASK-be48e27b960e
type: task
slug: a-devshell-for-the-pin-updaters
title: A devShell for the pin updaters
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: done
scope:
  - flake.nix
  - lib/updater.sh
  - features/*/update.sh
blocked_by: []
done_criteria: |
  nix eval .#devShells.x86_64-linux.default evaluates and the shell resolves curl, jq, nix, bats, shellcheck and shfmt; nix develop --command ./update-all.sh --check exits 0 on a clean tree and 1 when a pin moves or an update.sh is a copy.
criteria_by: creator
method: tdd
proof:
  - type: commit
    ref: 26f5474
    criteria: 483f7a2a60bc
    via: submitted
schema: 4
version: 2
---

DESIGN.md names this the second placeholder. lib/updater.sh needs curl, jq and nix; update-all.sh
also refuses copy-instead-of-symlink updaters, and the bats suites need bats. Right now the toolchain
is whatever the installed profile happens to carry, so a updater run on a fresh machine fails on a
missing dependency rather than on a pin.

Smallest version: one devShell declaring those tools, no per-feature shells.
