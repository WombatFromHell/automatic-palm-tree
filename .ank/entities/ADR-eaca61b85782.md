---
id: ADR-eaca61b85782
type: adr
slug: disko-owns-mounts-and-only-a-vm-host-may-own-a-d
title: Disko owns mounts, and only a host that owns its whole disk may partition it
created: 2026-11-05T20:29:59Z
author: josh@methyl-bazzite
status: superseded
scope:
  - flake.nix
  - lib/default.nix
  - hosts/**
  - lib/filesystems.nix
  - lib/host-options.nix
  - lib/features.nix
  - lib/builders.nix
  - modules/host-facts.nix
constraint: |
  A host that opts into the nixos-disko feature gets its fileSystems from disko (fsLib.mkMounts stays for hosts without one), its layout declares only partitions NixOS owns, content.type = "gpt" is asserted only where config.flakeHost.ownsWholeDisk is true, and no disko invocation may carry --mode disko, destroy, or --yes-wipe-all-disks for a host that does not own its drive.
ratified: ed237ceb1633
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-06T03:30:01Z
schema: 4
version: 6
---

Disko's gpt type runs `sgdisk --clear` when `blkid` reports nothing for the whole disk, and for each partition it names it tries `sgdisk --new` first and, on failure, falls back to `--partition-guid`, `--change-name` and `--typecode` on whatever already sits at that index. On a disk shared with Windows that fallback rewrites the GUID, name and type code of the Windows partition — the data survives, the boot metadata Windows depends on does not. So drive ownership is the thing worth gating.

The fact that carries it is `ownsWholeDisk`, named for the consequence the guard enforces: true means a layout may partition the whole drive, false means a layout may declare only partitions NixOS owns. methyl-nixos sets it true (it owns its VM disk); methyl and propyl leave it false, because a Windows install shares their disk. `isQemuVM` is not the signal and is retired by ADR-a742baa19dd5: its value decides a display session, not a partition table, and no host sets it true today.

The non-destructive half of disko is safe on a shared disk: filesystem and btrfs content both guard with blkid (no mkfs on an existing filesystem) and `btrfs subvolume show` (no subvolume creation when it already exists), so a layout over existing NixOS partitions converges rather than rewrites. `disko._config` sets `fileSystems` itself, which is why fsLib.mkMounts becomes the path for hosts that do not opt in, and why a host that does opt in regenerates hardware-configuration.nix with `nixos-generate-config --no-filesystems` so the generated file carries kernel modules, swapDevices and hostPlatform only.

Layout parity is what makes adoption on a live host safe: btrfs is the default filesystem (ext4 and xfs are supported through disko's filesystem type), the subvolume tree stays as today's — @, @home, @log, @cache, @nix, @snapshots mounted at /.snapshots, @swap created but unmounted — and swapDevices stays empty.
