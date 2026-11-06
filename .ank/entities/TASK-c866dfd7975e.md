---
id: TASK-c866dfd7975e
type: task
slug: terraform-sh-reproduces-a-declared-partition-rec
title: terraform.sh reproduces a declared partition recipe and verifies the disk
created: 2026-11-06T15:42:13Z
author: josh@methyl-bazzite
status: open
scope:
  - terraform.sh
  - install.sh
  - hosts/**
  - modules/terraform-recipe.nix
  - tests/terraform.bats
blocked_by: []
done_criteria: |
  hosts/<host>/terraform.json declares the layout. terraform.sh finds its drive by the recipe's own fingerprints (exactly one candidate, otherwise refuse), refuses a drive that is not GPT and a tableless drive carrying a signature, refuses before any write when the free gaps cannot hold the recipe, reproduces a clean GPT table plus every partition, filesystem and subvolume the recipe defines when the recipe declares owns=true, adopts and appends into free space without resizing, renaming or retyping an entry that already exists when owns=false, does every destructive step through the confirm gate (--force is the only non-interactive override), prints a recipe read-only with --emit, and exits 0 only when a re-read of the drive shows each entry's GPT type, filesystem signature, label and size as declared. terraform.sh --verify reports that verdict with no writes, install.sh deploy uses it as its precondition, and recipe owns must equal flakeHost.ownsWholeDisk.
criteria_by: creator
verify: [gate]
method: tdd
schema: 4
version: 2
---

ADR-b77ec913151f says terraform.sh never creates a partition entry. Reproducing a recipe needs an
amendment: appending into free space is allowed, modifying, resizing, renaming or retyping an existing
entry never is. Execution checklist: .pi/PLAN-terraform-recipe.md (R1 discovery+plan, R2 free-space
precheck, R3 append under --force, R4 tableless drive, R5 mkfs+verify+preserve, R6 nix validation and
install.sh wiring), ending with .pi/PLAN-methyl-vm-deploy.md phase 3.
