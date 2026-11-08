---
id: TASK-fbbf54a7978b
type: task
slug: deploy-methyl-onto-the-iso-vm-through-prepare-te
title: deploy methyl onto the ISO VM through prepare, terraform and deploy
created: 2026-11-06T15:42:22Z
author: josh@methyl-bazzite
status: in_progress
scope:
  - install.sh
  - terraform.sh
  - hosts/methyl/**
  - tests/install.bats
blocked_by: [TASK-c866dfd7975e, TASK-bc397ac63426, TASK-8364b000c9e9]
done_criteria: |
  On the nixos-minimal ISO VM, install.sh --stage prepare methyl exits 0 and leaves the partition table byte-identical; --stage terraform methyl reproduces hosts/methyl/terraform.json and terraform.sh --verify then passes with every partition that existed before unchanged and byte-identical; --stage deploy methyl lands the system closure on a disk-backed store under the terraform mount and writes the boot loader without touching a partition Windows owns; after the operator sets passwords, --stage reboot boots the installed system and the admin user is reachable by ssh key. The evidence is logged, not asserted by the gate.
criteria_by: creator
verify: [gate]
schema: 4
version: 3
---

Execution checklist: .pi/PLAN-methyl-vm-deploy.md, phases 1-6. The VM stands in for methyl, which is
unreachable on tailscale. Measured constraints it carries: 7.8G RAM with no swap, /nix/store an
overlay whose upper is a 3.9G tmpfs, and a 30G virtio drive. The closure build must go to the disk
store, never tmpfs; if it OOMs the answer is more zram, not a tmpfs store. Passwords stay the
operator's step: --stage reboot refuses without them by design.
