---
id: TASK-acd3a3cd2e12
type: task
slug: the-closure-moves-over-9p-at-a-pinned-msize
title: The closure moves over 9p at a pinned msize
created: 2026-11-11T00:16:22Z
author: josh@methyl-bazzite
status: done
scope:
  - tests/vm-shell.sh
blocked_by: [TASK-c5f48738a9b5]
done_criteria: |
  the generated guest override sets virtualisation.msize to one value the measured run settled on; a --push --boot run prints the same SHELL OK markers as the baseline and its registration span is under the baseline recorded by TASK-c5f4, with the deploy guest peak_guest_mb still under cap+64.
criteria_by: creator
proof:
  - type: commit
    ref: 3c864f8
    criteria: 81475fbe9768
    via: submitted
schema: 4
version: 4
---

Pinned nixpkgs defaults virtualisation.msize to 16384 and passes it to every 9p mount (qemu-vm.nix:447, :1486), so the 88 MiB/s registration is a small-msize number. The option description names the tradeoff: higher msize costs RAM, and the deploy guest is capped at 1300M with a measured peak of 1311. Measure before picking 1048576.
