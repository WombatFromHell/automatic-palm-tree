---
id: ADR-1341f73c7cae
type: adr
slug: exactly-one-kernel-feature-per-host
title: Exactly one kernel feature per host
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - lib/features.nix
  - features/nixos-cachyos/nixos.nix
  - features/nixos-kait2en/nixos.nix
  - hosts/**/*.nix
constraint: |
  A host lists at most one of nixos-cachyos and nixos-kait2en in features, and kernel pinning must not be added through a host-local nixosModules file, which bypasses the guard.
enforced_by:
  - lib/features.nix#resolveFeaturePaths
ratified: 98713aaf186a
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

Both kernel features write boot.kernelPackages at mkDefault, so a host listing two is an
authoring error that the module system reports only as "defined multiple times" with two store
paths and no host name. resolveFeaturePaths rejects it where the feature list becomes module
paths, naming the host's own list.

shortcut: the guard reads the host's features list only; a kernel module imported through a
host-local nixosModules file bypasses it. No host does that today
(hardware-configuration.nix sets kernelModules, never kernelPackages).
