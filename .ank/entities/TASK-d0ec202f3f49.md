---
id: TASK-d0ec202f3f49
type: task
slug: eval-only-cache-pre-flight-as-an-apps-output
title: Eval-only cache pre-flight as an apps output
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: done
scope:
  - flake.nix
  - lib/default.nix
  - modules/caches.nix
  - features/**/*.nix
blocked_by: []
done_criteria: |
  nix run .#apps.x86_64-linux.cache-check -- <host> exits 0 when every cache the host's enabled features require is in flakeCache.enable, exits 1 naming each cache that is not (modules/caches.nix's warning wording), and its eval stays inside tests/nix-eval.sh's cap with bash tests/run.sh green.
criteria_by: creator
method: tdd
proof:
  - type: commit
    ref: 0a2a302
    criteria: bd755f2e3b52
    via: submitted
schema: 4
version: 2
---

DESIGN.md lists this as a placeholder ergonomics we do not implement (no packages, devShell or
apps output today). Whether a cache answers is not a configuration value, so the pre-flight reports
what the host asks for versus what it enables — the same required/missing computation modules/caches.nix
already does — instead of probing the network.

The value is real: a host that disables a cache its kernel feature needs compiles a kernel on the
smallest machine, and today that is only discovered after the rebuild starts.
