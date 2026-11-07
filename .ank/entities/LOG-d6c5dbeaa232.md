---
id: LOG-d6c5dbeaa232
type: log
title: "ESP adoption on a shared drive: terraform.sh resolves the ESP entry by label symlink, by a vfat"
created: 2026-11-07T04:44:33Z
author: josh@methyl-bazzite
scope:
  - hosts/methyl/**
  - hosts/methyl-base/**
  - install.sh
  - terraform.sh
  - tests/terraform.bats
  - hosts/methyl/terraform.json
about: TASK-bc397ac63426
seq: 6
schema: 4
version: 1
---

 signature under the entry's label, then by a blank partition whose GPT type is the ESP GUID (C12A7328... — firmware scans that GUID; the FAT32 GUID is a data volume). default_type for vfat is now the ESP GUID, so an ESP terraform.sh creates is one firmware can boot. The ESP is settled before place_creations: on a drive this host does not own an unresolved ESP entry refuses, naming the FAT partitions and their labels, so no boot partition is ever appended to somebody else's drive. flags mode no longer reads a blank Basic Data partition as an ESP candidate. VM at 192.168.1.237 read-only: nvme0n1 has one partition, EFI System type, vfat labelled boot, 1G — methyl's esp entry (label boot, 512M) adopts it; the root goes into the ~29G free space. --emit/--verify on that VM need root (blkid and sfdisk cannot open the block device as the nixos user), and tests/deploy-loop.sh needs local root; the proof here is the fixture tier.
