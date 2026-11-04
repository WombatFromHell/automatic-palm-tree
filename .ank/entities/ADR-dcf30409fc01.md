---
id: ADR-dcf30409fc01
type: adr
slug: a-must-throw-check-is-a-tests-red-guard-never-tr
title: A must-throw check is a tests/red guard, never tryEval
created: 2026-11-04T17:24:56Z
author: josh@methyl-bazzite
status: accepted
scope:
  - tests/red/*.nix
  - tests/run.sh
constraint: |
  A "this must throw" check is a tests/red/*.nix guard whose first line is # expect: <substring>, gated on exit status by tests/run.sh; builtins.tryEval cannot gate a deferred error in this Nix, so it must never stand in for a guard.
amends: [ADR-5eb78b01a869]
ratified: 829123d3a88c
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:55:17Z
schema: 4
version: 2
---

The accepted text reads "whose first line is ," - the literal was dropped when the entity was
created, so the rule no longer names the contract the gate enforces. tests/run.sh:220 cuts
'# expect: ' off line 1 of every guard and matches the substring against the throw, and all 13
guards carry it. A contributor reading the rule alone could ship a guard with no marker and have the
gate compare an empty string, which matches any error.

No code change: the guards and the parser already agree. This only repairs the text.
