---
id: LOG-cb0eda372649
type: log
title: "slice R1b green: --emit is read-only recipe generation -- JSON on stdout, guidance on stderr, owns"
created: 2026-11-06T17:40:57Z
author: josh@methyl-bazzite
scope:
  - terraform.sh
  - install.sh
  - hosts/**
  - modules/terraform-recipe.nix
  - tests/terraform.bats
about: TASK-c866dfd7975e
seq: 4
schema: 4
version: 1
---

 always false, only partitions whose blkid signature is ext4/vfat/btrfs, every left-out partition named by its GPT name, mounts guessed and announced, sizes exact off the table, refuses no-table/nothing-reproducible/several-disks/--emit-with-recipe. ADR-2e63b3079610 proposed. R1's 'recipe must label the vfat partition' was stricter than ADR-b77ec913151f and is relaxed: a Windows ESP has no label, so the ESP is found by its vfat signature or GPT type. 25/25 tests/terraform.bats, gate shellcheck clean, install.bats 33. --verify half of the checkpoint is owed by R3/R6.
