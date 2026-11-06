---
id: TASK-de3e7c0e3382
type: task
slug: methyl-nixos-declares-its-layout-instead-of-inhe
title: methyl-nixos declares its layout instead of inheriting generated mounts
created: 2026-11-05T20:30:39Z
author: josh@methyl-bazzite
status: done
scope:
  - hosts/methyl-nixos/**
  - tests/configs.nix
blocked_by: [TASK-ebfd99fcecfb]
done_criteria: |
  bash tests/run.sh passes; nix eval of methyl-nixos config.fileSystems equals the mount set hosts/methyl-nixos/hardware-configuration.nix declares today (same mountpoints, btrfs subvolume tree, /.snapshots mounted, @swap created unmounted) with swapDevices = [], boot.loader.systemd-boot.enable and boot.loader.efi.canTouchEfiVariables true, and config.flakeHost.ownsWholeDisk true; hardware-configuration.nix keeps boot.initrd.availableKernelModules, boot.initrd.kernelModules and nixpkgs.hostPlatform only; nix build .#nixosConfigurations.methyl-nixos.config.system.build.diskoScript succeeds.
criteria_by: creator
verify: [gate]
method: tdd
proof:
  - type: test
    ref: local/6997062b732c@a377dfa
    tree: scope/21a799224f9a
    criteria: e382348a2efe
    verifier: gate@dc484de6fdb9
    via: verifier
schema: 4
version: 3
---

methyl-nixos is the host where disko can be exercised against a real disk without touching anyone else's partitions: it owns its whole drive, and its btrfs tree already exists, so the layout converges instead of rewriting (blkid guards mkfs, btrfs subvolume show guards subvolume creation). Adopting it on the existing partitions is the choice, not a fresh gpt layout — the gpt form is what the guard admits here, and it can come later as an image/boot test.

isQemuVM is set true on this host: it imports profiles/qemu-guest.nix and reports false today through hosts/methyl-base/core.nix, which is the fact the guard reads.
