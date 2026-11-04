---
id: TASK-8a5ccb7dfd5b
type: task
slug: a-host-that-enables-kde-and-gnome-says-which-ses
title: A host that enables KDE and GNOME says which session is dropped
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: done
scope:
  - features/nixos-kde/nixos.nix
  - features/nixos-niri/nixos.nix
  - features/nixos-gnome/nixos.nix
  - tests/home.nix
blocked_by: []
done_criteria: |
  a fixture host enabling nixos-kde and nixos-gnome produces a warning naming the dropped Plasma session (asserted with tests/support.nix's assertWarnStubs), and the same fixture produces no warning when only one of them is enabled.
criteria_by: creator
method: tdd
proof:
  - type: commit
    ref: 6f1cf14
    criteria: 0c9519295429
    via: submitted
schema: 4
version: 2
---

features/nixos-kde/nixos.nix:7: GDM owns the greeter once features.gnome is on, so kdeLogin is
false and the Plasma session disappears from the login screen while KDE apps remain installed. No
host enables both today, so the trap is for the next host author, and modules/warnings-gate.nix
turns the warning into a build failure, which is what makes it impossible to miss.
