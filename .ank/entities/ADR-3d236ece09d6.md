---
id: ADR-3d236ece09d6
type: adr
slug: mount-options-come-from-the-host-s-own-mount-con
title: mount options come from the host's own mount config, and --emit copies them
created: 2026-11-06T23:19:04Z
author: josh@methyl-bazzite
status: accepted
scope:
  - terraform.sh
  - tests/terraform.bats
  - tests/deploy-loop.sh
  - hosts/methyl-nixos/nixos.nix
constraint: |
  terraform.sh mounts every filesystem it mounts with the options hosts/<host>/nixos.nix declares for that filesystem: btrfs defaults to noatime,compress=zstd and a vfat ESP to fmask=0077,dmask=0077. A recipe entry may declare its own options as a comma-separated list, which wins over the defaults and is refused if it contains a space. --emit copies the defaults for each partition it emits, so an emitted recipe carries the options the host will mount with.
ratified: 01f7bab91b70
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-06T23:43:54Z
  - by: josh@methyl-bazzite
    at: 2026-11-07T00:06:48Z
schema: 4
version: 3
---
