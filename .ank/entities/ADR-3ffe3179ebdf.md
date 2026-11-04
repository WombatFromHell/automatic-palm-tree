---
id: ADR-3ffe3179ebdf
type: adr
slug: a-host-eval-runs-inside-a-bounded-memory-scope-w
title: A host eval runs inside a bounded memory scope with a no-bus fallback
created: 2026-11-04T16:50:02Z
author: josh@methyl-bazzite
status: accepted
scope:
  - bootstrap.sh
  - tests/run.sh
  - tests/nix-eval.sh
constraint: |
  bootstrap.sh wraps its rebuild in systemd-run --user --scope with MemoryHigh, MemoryMax and MemorySwapMax, probes that a user bus exists first, and falls back to a plain exec when it does not; the gate proves the wrap from the stub's cgroup rather than by grepping the script.
ratified: c7b355105d49
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T18:06:15Z
schema: 4
version: 2
---

A host eval is about 2.3GB of anonymous RAM in the client. MemoryHigh throttles first, MemoryMax
kills, MemorySwapMax bounds any spill; the build itself runs in the nix-daemon outside the scope.
The pid in the unit name avoids "already loaded" after an OOM, and a socket can exist with no user
systemd behind it, so the script probes with a throwaway scope before wrapping the real one.

A newcomer who drops the wrap turns a rebuild into an OOM on the host; one who greps for the scope
in the gate proves nothing, which is why the stub reports its own cgroup.
