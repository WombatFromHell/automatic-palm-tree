---
id: ADR-29b6090bccd8
type: adr
slug: oom-limits-land-on-the-monitored-cgroups-and-mem
title: OOM limits land on the monitored cgroups, and MemoryMax= on -.slice is the RAM ceiling
created: 2026-11-07T18:23:57Z
author: josh@methyl-bazzite
status: proposed
scope:
  - features/nixos-oom/**
  - tests/oomd.nix
  - hosts/methyl-base/**
constraint: |
  systemd-oomd limits must be written on the cgroups systemd-oomd monitors (-.slice and user.slice, each declaring ManagedOOMSwap=kill), and the bound on RAM usage is MemoryMax= on -.slice, because oomd itself has no memory-usage knob and a limit written on a unit nobody monitors binds nothing.
schema: 4
version: 1
---

The measured input is methyl-bazzite: Strata sits at roughly 90% of methyl's 32GB during inference, and a run that pushes past that has locked the machine. The rule the feature now implements is a danger band, not a threshold: nothing is throttled below 93%, 93-97% is where reclaim pushes pages into zswap and systemd-oomd looks for a candidate, and 97% is the line the kernel is allowed to cross nothing past.

Verified against systemd's own documentation, before any of this was written:

- oomd.conf(5): SwapUsedLimit fires only when the fraction of memory used AND the fraction of swap
  used both exceed it, and only on eligible descendants of a cgroup configured for
  ManagedOOMSwap=. Nixpkgs' oomd module sets ManagedOOMMemoryPressure=kill and never ManagedOOMSwap,
  so the swap knob features/nixos-oom/nixos.nix had been setting since its first commit did nothing.
- systemd.resource-control(5): ManagedOOMPreference=avoid de-prioritises the cgroup and needs xattr
  support; for swap candidates it is respected only when the cgroup is owned by UID 0. Setting it next
  to ManagedOOMMemoryPressure=kill on user@ marked the session and then refused to act inside it — the
  session is exactly where Strata runs.
- systemd.resource-control(5): MemoryHigh= is the main throttle, MemoryMax= is the last line of defense
  and invokes the OOM killer inside the unit, and both accept a percentage relative to installed memory.
  Percentages are why one default serves methyl (32GB), propyl, and the methyl-nixos VM.
- systemd.resource-control(5) does not carry ManagedOOM* into the kernel kill: ManagedOOMPreference
  moves oomd's candidates only, so display-manager also gets OOMScoreAdjust= to stay out of a kernel
  OOM round.

The numbers, as defaults rather than per-host values: swapUsedLimit 75%, memPressureLimit 60% at the
slice (it now beats nixpkgs' mkDefault 80% on user.slice, which is where kills happen),
memPressureDuration 15s, memoryHigh 93%, memoryMax 97%. On methyl's 4GiB swapfile 75% is 3GiB, crossed
inside the danger band and before the ceiling; 30s of sustained pressure is a lockup, not a warning, so
the duration came down.

What the gate proves is config shape: tests/oomd.nix asserts the markers and the limits on the slices,
that the session carries no preference, that memoryMax=null removes the ceiling, and that dropping
swapUsedLimit keeps DefaultMemoryPressureDurationSec (both keys used to sit inside one mkIf, so opting
out of the swap rule silently took the duration with it). It cannot prove behaviour. The behaviour has to
be read off methyl-bazzite while Strata runs: journalctl -u systemd-oomd, /proc/pressure/memory,
/proc/swaps and -.slice's memory usage, confirming usage never crosses 97% and that the hog is what dies.

Two consequences a reviewer should weigh, both left alone rather than pre-empted:

- memoryMax applies to every host that lists the feature, including methyl-nixos, whose install run
  (TASK-fbbf54a7978b) carries 7.8G RAM with a tmpfs store. If a deploy is killed by the ceiling the fix
  is features.oomd.memoryMax = null on that host, or more zram, which is what that task already says.
- Killing Strata mid-run is what the danger band is for. If losing a run is unacceptable, the alternative
  is ManagedOOMPreference=avoid on Strata's own unit and letting MemoryHigh throttle it instead.

features/zswap keeps its 4GiB swapfile: resizing it means a swapoff during the switch, which this
decision does not take on.
