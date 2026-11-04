---
id: TASK-4e627ec007af
type: task
slug: unitname-escapes-systemd-paths-instead-of-swappi
title: unitName escapes systemd paths instead of swapping slashes
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: open
scope:
  - lib/filesystems.nix
  - features/nixos-automounts/nixos.nix
  - tests/filesystems.nix
  - tests/mounts.nix
blocked_by: []
done_criteria: |
  fsLib.mkUnitMounts emits the escaped unit name for a mount point containing '-' or a space (utils.escapeSystemdPath), the mount's requires/after name equals the automount it pairs with, and tests/filesystems.nix, tests/mounts.nix and tests/configs.nix stay green with a new tests/red guard for a path the current replaceStrings would corrupt.
criteria_by: creator
method: tdd
schema: 4
version: 1
---

lib/filesystems.nix:22 says it plainly: unitName assumes paths without - or special characters and
names utils.escapeSystemdPath as the upgrade. replaceStrings ["/"] ["-"] turns "/mnt/a-b" into
"mnt-a-b", which collides with the unit for "/mnt/a/b" — a mount would then require the wrong
automount. No host hits this today, so it is latent, not cosmetic.
