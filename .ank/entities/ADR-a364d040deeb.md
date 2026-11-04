---
id: ADR-a364d040deeb
type: adr
slug: configuration-warnings-fail-the-build
title: Configuration warnings fail the build
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - modules/warnings-gate.nix
  - modules/defaults/nixos.nix
  - modules/defaults/home-manager.nix
constraint: |
  Both namespaces import modules/warnings-gate.nix so any entry in config.warnings fails the build; a genuinely unavoidable warning is filtered by prefix inside that assertion, never by deleting the assertion.
ratified: 6fe876e1586d
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T18:06:15Z
schema: 4
version: 2
---

A warning is printed, never fatal: lib.asserts.checkAssertWarn throws only on failed assertions,
and forcing toplevel (config.system.build.toplevel or Home Manager's activationPackage) already
forces config.assertions and config.warnings. Asserting the warnings list therefore costs nothing
at eval and turns nix build, nix flake check and nixos-rebuild switch into a failure before any
builder runs.

Home Manager throws on failed assertions when its activation package is forced, and nixpkgs'
assertions module declares both options — that is why the gate is imported on the HM side too.
