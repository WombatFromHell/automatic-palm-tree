---
id: ADR-e2ab6999f0a1
type: adr
slug: a-rule-is-published-once-and-a-stale-accepted-co
title: a rule is published once, and a stale accepted copy is superseded
created: 2026-11-06T23:50:08Z
author: josh@methyl-bazzite
status: accepted
scope:
  - .ank/entities/*.md
constraint: |
  One accepted ADR carries each rule. The corpus migration published the cache-registry, feature-owned-group, pkgs.unstable, shipped-shell-linting and feature-module-discovery rules twice, as an amends copy and a supersedes copy of the same predecessor; both are live. A must-throw check is now an expectedError attribute (ADR-fb331caa521d), so the copy that still describes a tests/red/*.nix guard is stale. These six entities are superseded here and decide nothing new: the surviving copies are ADR-29b0831fc6be, ADR-da5ab1916f11, ADR-a6c73e1ae002, ADR-f21cdaed28ee, ADR-f704f8e1925b and ADR-fb331caa521d.
supersedes: ADR-dcf30409fc01
ratified: 37cf6977784c
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-07T00:01:29Z
  - by: josh@methyl-bazzite
    at: 2026-11-07T00:06:48Z
schema: 4
version: 3
---
