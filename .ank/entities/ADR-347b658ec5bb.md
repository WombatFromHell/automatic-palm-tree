---
id: ADR-347b658ec5bb
type: adr
slug: the-kernel-default-sits-at-override-priority-110
title: The kernel default sits at override priority 1100
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - modules/defaults/nixos.nix
  - features/nixos-cachyos/nixos.nix
  - features/nixos-kait2en/nixos.nix
constraint: |
  boot.kernelPackages is defaulted with lib.mkOverride 1100 so a kernel feature's mkDefault (1000) and a host's plain assignment (100) both win; do not change that level or make a kernel feature assign plainly.
ratified: ac23332ca509
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

1100 is weaker than lib.mkDefault (1000), which is exactly what lets nixos-kait2en and
nixos-cachyos pin the kernel while a host that assigns boot.kernelPackages directly still gets
its own kernel. Setting the default to mkDefault would make every host pin unchangeable; making
a feature assign plainly would make it beat a host's explicit choice.

Note cachyos pins the package *set* (linuxPackages-…), not the bare kernel derivation
(linux-…), which fails in boot/kernel.nix.
