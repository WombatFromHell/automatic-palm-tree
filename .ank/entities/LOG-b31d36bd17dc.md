---
id: LOG-b31d36bd17dc
type: log
title: "closed: superseded: methyl-nixos deploys correctly with disko managing the disk (verified on the"
created: 2026-11-06T05:40:37Z
author: josh@methyl-bazzite
scope:
  - flake.nix
  - tests/outputs.nix
  - tests/build-harness.sh
about: TASK-d3654167eec2
seq: 1
schema: 4
version: 1
---

 deploy path), and the VM tier cannot prove the non-destructive half anyway -- it renumbers devices to /dev/vda, so no foreign partition is ever observed. The disk-fixture tier (.pi/PLAN-terraform-fixture.md) proves layout plus byte parity on files, at ~5s and ~80MB instead of a 15GB VM.
