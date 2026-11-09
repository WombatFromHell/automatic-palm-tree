---
id: ADR-e14303caba55
type: adr
slug: a-recipe-assigns-its-filesystem-identities-and-m
title: a recipe assigns its filesystem identities, and mkfs is told them
created: 2026-11-09T04:01:58Z
author: josh@methyl-bazzite
status: proposed
scope:
  - terraform.sh
  - install.sh
  - lib/filesystems.nix
  - tests/terraform.bats
  - tests/install.bats
constraint: |
  A recipe declares the filesystem identities it formats; where it declares none terraform.sh derives them from the recipe and hands them to mkfs, --record writes them into the recipe file it was given rather than onto the drive, and deploy refuses a recipe that mounts a partition declaring none.
enforced_by:
  - terraform.sh#format_blank
  - terraform.sh#record_recipe
  - install.sh#deploy
  - lib/filesystems.nix#mountsFromRecipe
amends: [ADR-8cd71b226ffb]
schema: 4
version: 1
---

A uuid read off the drive after the fact is impure: the config the flake derives from the recipe mounts a filesystem whose identity the recipe did not know until the run finished, so the install needs a fold step that copies `blkid` output back into the repo before the closure can be built. That fold is what made `--record` write `<mount>/terraform.json`, and it is why a first install could never boot its own generation.

The identity of a filesystem is assignable. `mkfs.ext4 -U`, `mkfs.btrfs -U`, `mkfs.xfs -m uuid=` and `mkfs.fat -i` all take one, so a run can format a partition to the identity its recipe names. The identity is derived by hashing `"<host>/<partition name>"` with `sha256sum` and rendering a v4 UUID — a 32-bit volume serial, `05A7-605A` shape, for vfat, because `mkfs.fat` takes a hex volume id and blkid reports it back in that form. The host is in the hash, so two hosts declaring the same partition names do not answer to one another; the partition name is in it, so one host's partitions do not answer to each other. Derived rather than random, so the same recipe records the same identities twice and a checked-in recipe reproduces the same drive.

`--record` writes the recipe it was **given**, in place. A filesystem this run adopted keeps the uuid it already carries — re-cutting it would break the config that names it — and a partition this run formatted carries the identity it was formatted with. A recipe that already declares every identity writes nothing.

`deploy` still refuses a recipe that mounts a partition declaring no uuid, because a label is unique only within one drive and `/dev/disk/by-label` answers whichever drive enumerated first. What changes is where the uuids come from: the terraform stage records them into `hosts/<host>/terraform.json` itself, and the operator commits that file. `lib/filesystems.nix#mountsFromRecipe` is unchanged — it prefers `/dev/disk/by-uuid/<uuid>` over the label, and a vfat serial passes its shape check.

A block-level clone of an installed drive carries these identities, so `by-uuid` then answers both drives. That is true of uuids mkfs invented too; assignment makes it predictable rather than worse.
