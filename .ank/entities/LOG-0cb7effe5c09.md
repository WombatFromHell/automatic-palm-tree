---
id: LOG-0cb7effe5c09
type: log
title: terraform.sh written (ESP/root picked by sfdisk+blkid signature, blank-only format,
created: 2026-11-06T06:22:15Z
author: josh@methyl-bazzite
scope:
  - terraform.sh
  - install.sh
  - tests/terraform.bats
  - tests/disk-fixture.bash
  - tests/run.sh
  - flake.nix
about: TASK-14b69ca0a0e2
seq: 1
schema: 4
version: 1
---

 adopt-by-signature, UUID-declared blank refused before any write, table checksum 1MiB equal before/after); lib/confirm.sh holds the shared prompt gate; install.sh resolve()/terraform() branch on ownsWholeDisk so methyl and propyl take terraform.sh and methyl-nixos keeps disko; tests/terraform.bats proves the five scenarios on sparse image files with real mkfs/blkid/mtools (mount stubbed); tests/install.bats covers the branch; devShell gained util-linux/gptfdisk/dosfstools/mtools/e2fsprogs and run.sh runs the fixture suite only where those tools exist.
