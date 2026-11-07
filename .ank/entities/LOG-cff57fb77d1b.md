---
id: LOG-cff57fb77d1b
type: log
title: methyl is reachable now (ssh nixos@192.168.1.188, sudo -n works, no password). Its drive is
created: 2026-11-07T00:15:35Z
author: josh@methyl-bazzite
scope:
  - hosts/methyl/**
  - hosts/methyl-base/**
  - install.sh
about: TASK-bc397ac63426
seq: 2
schema: 4
version: 1
---

 observed, not assumed: /dev/vda, 32212254720 bytes, TYPE=disk, RM=0, PTTYPE empty — no partition table, no filesystem signature (the first 512 bytes read as zero). Repo rsynced to /tmp/flakeroot on the VM (RAM only); as root, install.sh --dry-run --stage prepare methyl resolves exactly one drive /dev/vda, prints "methyl shares /dev/vda (disko is not in play; terraform.sh adopts the partitions it declares)" and "prepare ok: partition table unchanged (b6d81b360a5672d80c27430f39153e2c)"; --stage terraform prints "[dry-run] ./terraform.sh --dry-run --disk /dev/vda --mount /mnt --root-fs ext4 --root-device /dev/disk/by-label/nixos --esp-device /dev/disk/by-label/boot" and runs nothing. No disko script is built. terraform.sh --dry-run --disk /dev/vda exits 2 ("no partition table on /dev/vda: terraform.sh never partitions a drive it does not own — create the ESP and the root partition first"), --emit exits 2 ("no partition table on /dev/vda: nothing to emit"), and the first-megabyte checksum is b6d81b360a5672d80c27430f39153e2c before prepare, after terraform, and after both terraform.sh calls: byte-identical. So the disko-era clause "prints the current partition table and disko dry-run" cannot be met and must not be: methyl takes terraform.sh (ADR-b77ec913151f), and a layout only reaches this drive when it is adopted deliberately. The Windows-shaped-drive guarantee is proven on a real loop device instead (tests/deploy-loop.sh steps 2, 5, 6: ESP loader byte-identical, foreign regions unchanged, partition table unchanged).
