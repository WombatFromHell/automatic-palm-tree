---
id: TASK-43c24aca98ad
type: task
slug: prove-hm-brave-s-store-layout-with-a-fixture-bui
title: Prove hm-brave's store layout with a fixture build
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: done
scope:
  - features/hm-brave/_package.nix
  - tests/appdir.nix
  - tests/run.sh
blocked_by: []
done_criteria: |
  a fixture build re-runs features/hm-brave/_package.nix's real unpack and install phases over a synthetic rpm tree (no download, no compile) and asserts the binary lands in bin/ and the desktop entry in share/, and bash tests/run.sh prints ok for that tier.
criteria_by: creator
method: tdd
proof:
  - type: commit
    ref: d8ed107
    criteria: b91bf0435aaf
    via: submitted
schema: 4
version: 2
---

TEST_DESIGN lists hm-brave as the store layout not proven: appdir.nix covers hm-ghostty and
yazi-install.nix covers hm-yazi, and the other six _package.nix files are covered input-side only
(pins.nix plus the expander parity diff). A pin bump for brave changes the rpm layout, and nothing
in the gate notices until the activation package fails on the host.

Follow the existing fixture shape: a synthetic tree, the real installPhase, the build's exit status
read by the gate.
