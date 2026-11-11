---
id: LOG-0b4ee4fd9256
type: log
title: "Interactive --push run (logs/vm-shell-1794379285.log): push_build_secs=6, push_rc=0 secs=8,"
created: 2026-11-11T06:49:07Z
author: josh@methyl-bazzite
scope:
  - tests/vm-shell.sh
  - tests/vm-run.sh
about: TASK-c5f48738a9b5
seq: 3
schema: 4
version: 1
---

 push_cache=new, guest_build_secs=7, boot_wait_secs=13, ssh=ok, peak_guest_mb=1300, guest powered off cleanly. It recorded no register/prepare/deploy marker and no total because the interactive path types no probe (tests/vm-shell.sh:336 — the probe is --script only) and because cat >&9 blocked on stdin after qemu closed the console, so the run never reached the end markers. Fixed: the forward is backgrounded and the script waits for qemu then kills it, so poweroff now ends the run and writes total_secs=/log=. Asserted against a fifo stand-in for the console: foregrounded cat hangs (timeout rc=124), backgrounded+wait+kill reaches the end. shellcheck -x and bash -n clean, vm-check.bats unchanged at 17.
