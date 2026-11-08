---
id: ADR-97fb20bfd175
type: adr
slug: the-staging-mount-set-is-the-mount-set-the-host
title: The staging mount set is the mount set the host declares
created: 2026-11-08T16:21:01Z
author: josh@methyl-bazzite
status: proposed
scope:
  - terraform.sh
  - install.sh
  - tests/terraform.bats
  - tests/install.bats
  - hosts/methyl-nixos/nixos.nix
  - hosts/methyl-test/nixos.nix
constraint: |
  Every entry in a host fileSystems is mounted under the install root before nixos-install runs: terraform.sh mounts each subvolume of the tree it creates at the path that host mounts it at, with the root options, and install.sh deploy refuses before the prompt while any declared mount is not live under the root.
enforced_by:
  - terraform.sh#owned_run
  - install.sh#deploy
amends: [ADR-eaca61b85782]
schema: 4
version: 1
---

ADR-eaca61b85782 fixed the *names* of the btrfs tree (layout parity) but never said the tree is mounted, and its "@swap created but unmounted" line already contradicts the host configs, which mount /var/lib/swap from @swap. The gap is not cosmetic.

Owned mode creates @, @home, @nix, @log, @cache, @snapshots and @swap and mounts @ at the install root. deploy then writes the closure into <root>/nix/store, a directory inside @, and postdeploy writes ssh keys into <root>/home, inside @ too. At boot the initrd mounts @nix over /nix, @home over /home and the rest over their paths, so every one of those writes is hidden by an empty subvolume: /nix/store is empty, stage 2 init (/nix/store/.../nixos-stage-2/init) is not there, and systemd lands in emergency.target. The install reports success and the host never boots.

So parity has two halves: the tree that exists, and the tree that is mounted. terraform.sh owns the staging side — it mounts each sibling of @ on the root device with -o subvol=<name> ahead of the root own options, reusing mount_extra, so the mkdir, the adopt-if-mounted guard and --dry-run come along with it. install.sh owns the drift guard: deploy reads the declared mount paths from the same single eval that names the devices and refuses before its one prompt when any of them is not mounted under the root, naming the missing paths. A host that adds a subvolume mount staging does not lay down then fails loudly at install rather than silently at boot.

/ and /boot are not re-checked by deploy: the root has store_mount (a disk-backed mount of the root or of /nix, never tmpfs), and the ESP is mounted and verified by terraform.sh itself.
