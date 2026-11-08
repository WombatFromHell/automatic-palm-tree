---
id: LOG-74ec9261ba5d
type: log
title: "staging now mounts the whole tree (terraform.sh: @home/@nix/@log/@cache/@swap/@snapshots under"
created: 2026-11-08T16:47:26Z
author: josh@methyl-bazzite
scope:
  - install.sh
  - terraform.sh
  - hosts/methyl/**
  - tests/install.bats
about: TASK-fbbf54a7978b
seq: 2
schema: 4
version: 1
---

 $mount with subvol= ahead of the root options, reusing mount_extra, so mkdir + adopt-if-mounted + --dry-run come free) and deploy refuses before its prompt while any path in the host's fileSystems is unmounted under $root (install.sh, fifth fact from the same eval). btrfs --root fixture had to grow to 300M: mkfs.btrfs sizes its free-space table from the device, so a 20MB image has ~26 inodes and a 7-subvolume tree needs ~1000 — mkfs fails after creating none. Gate green (exit 0, 19 verdicts): terraform.bats 80/240, install.bats 58/138, floors bumped (225->240, 133->138), terraform scope peak 1390MB of 1792MB. ADR-97fb20bfd175 proposed (amends ADR-eaca61b85782). VM half of the criterion still yours: no qemu on this box.
