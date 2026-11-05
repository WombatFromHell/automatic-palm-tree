---
id: TASK-40d9c6b2cc7c
type: task
slug: shared-eval-fixtures-one-bare-eval-factory-one-p
title: "Shared eval fixtures: one bare-eval factory, one package predicate, collapsed mount factories"
created: 2026-11-05T02:31:32Z
author: nix-unit-suite
status: done
scope:
  - tests/support.nix
  - tests/caches.nix
  - tests/warnings.nix
  - tests/home.nix
  - tests/wrap.nix
  - tests/filesystems.nix
blocked_by: []
done_criteria: |
  bash tests/run.sh exits 0 with no assertion removed or weakened.
criteria_by: creator
verify: [gate]
proof:
  - type: test
    ref: local/869310d706b7@661d306
    tree: scope/a8ff49ab0ee8
    criteria: fb23cb2a8e70
    verifier: gate@dc484de6fdb9
    via: verifier
schema: 4
version: 2
---

Audit findings F2-F5 in .pi/PLAN-suite-audit.md, measured first: lib.evalModules is hand-assembled at caches.nix:27, warnings.nix:10 and warnings.nix:21; (p.pname or p.name) is repeated at outputs.nix:34, wrap.nix:54, home.nix:29 and home.nix:34, where fxInstalled and installed are literal twins; filesystems.nix L6-L10 has five micro-factories, unit+mount1 always used together (10 sites) and has is a builtins.hasAttr wrapper; caches.nix:39 evalCfg is a pass-through wrapper over eval at 8 call sites.

These land before the nix-unit migration because the attrsets consume them: expr = (bareEval [stubs] opts).warnings reads better than a hand-built module list, and unitMount is what a test attribute wants.

Rejected in the audit, do not attempt here: merging mounts.nix into configs.nix per host (mounts first check is cross-host, one host per process cannot assert it); a shared factory for the four fixture builds (no shared >=5-line block once read).
