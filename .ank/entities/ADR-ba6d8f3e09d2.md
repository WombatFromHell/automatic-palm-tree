---
id: ADR-ba6d8f3e09d2
type: adr
slug: checks-are-generated-from-the-host-records
title: Checks are generated from the host records
created: 2026-11-04T16:49:02Z
author: josh@methyl-bazzite
status: accepted
scope:
  - flake.nix
constraint: |
  flake checks are generated from cfg.hostsWithPkgs per system by mkChecks, never enumerated by hand and never by forcing config.pkgs for every host, which costs about 500MB of eval RAM.
enforced_by:
  - flake.nix#mkChecks
ratified: 73dc9b37aab6
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

supportedSystems is lib.unique over the host records' system, and one check per configuration is
the derivation nix flake check would build for it. The value is unchanged, because pkgsFor is
built from host.system: a host outside the list still cannot hide behind a missing check.

A newcomer listing checks per host by hand reintroduces the eval cost the loader was shaped to
avoid.
