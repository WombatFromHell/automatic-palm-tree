---
id: LOG-84ca4ce82c0c
type: log
title: "the test VM (methyl-nixos, nixos-minimal ISO) is virtio: the drive is /dev/vda, not /dev/sda, and"
created: 2026-11-05T21:33:17Z
author: josh@methyl-bazzite
scope:
  - lib/host-options.nix
  - hosts/methyl-base/core.nix
  - features/nixos-kde/nixos.nix
  - tests/support.nix
  - tests/configs.nix
about: TASK-2a954f7519dc
seq: 1
schema: 4
version: 1
---

 its root is a 3.9GB tmpfs, so /nix/store has no room for the gate's built paths; two layout attempts crashed it, both after mkfs.btrfs started on the 30GB disk, so the filesystem creation is what to size down (smaller nodesize or a smaller partition) rather than assume it is free.
