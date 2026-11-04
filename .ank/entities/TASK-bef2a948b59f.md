---
id: TASK-bef2a948b59f
type: task
slug: readme-s-overlays-nix-shape-matches-the-shipped
title: README's _overlays.nix shape matches the shipped module
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: open
scope:
  - README.md
  - features/*/_overlays.nix
  - tests/loader.nix
blocked_by: []
done_criteria: |
  README states _overlays.nix is a module that sets config.nixpkgs.overlays (not {inputs,...}: [..]), and tests/loader.nix asserts every features/*/_overlays.nix evaluates as a module whose config carries nixpkgs.overlays.
criteria_by: creator
schema: 4
version: 1
---

README describes _overlays.nix as `{inputs, ...}: [ … ]`, an overlay function. The shipped one
(features/nixos-niri/_overlays.nix) is a module returning config.nixpkgs.overlays = lib.mkIf …, which
is what makes the overlay gateable on a feature option. The documented shape cannot be gated at all,
so writing it would silently drop the gate.

The assertion belongs in loader.nix next to the existing overlay-bearing-set check.
