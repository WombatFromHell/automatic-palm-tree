---
id: ADR-af12e4de7028
type: adr
slug: one-package-set-per-system-feature-overlays-appl
title: One package set per system, feature overlays applied at eval time
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - lib/default.nix
  - features/*/_overlays.nix
constraint: |
  lib/default.nix builds one package set per system with baseOverlay only; a feature overlay is a module that appends nixpkgs.overlays and must never be passed to import nixpkgs, because nixpkgs appends it at eval time so it can be gated on a feature option.
enforced_by:
  - lib/default.nix#pkgsFor
ratified: d084e8cead6d
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T18:06:15Z
schema: 4
version: 2
---

Every host here is x86_64-linux, so per-host instantiation was four copies of the same tree and
four of the unstable one. Feature overlays are deliberately not applied at construction: they
are modules setting nixpkgs.overlays, which nixpkgs appends to the pinned set at eval time, so an
overlay can depend on an option (nixos-niri swaps niri only when _spicy.nix says yes and the
wombatfromhell cache is substituted).

A newcomer who wires an overlay into pkgsFor freezes it for every host and loses the gate.
