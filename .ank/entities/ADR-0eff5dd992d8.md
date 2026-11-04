---
id: ADR-0eff5dd992d8
type: adr
slug: groups-are-published-per-feature-not-assigned-pe
title: Groups are published per feature, not assigned per user
created: 2026-11-04T16:49:27Z
author: josh@methyl-bazzite
status: accepted
scope:
  - modules/feature-options.nix
  - modules/defaults/nixos.nix
  - features/**/*.nix
constraint: |
  A feature publishes groups through extraGroups keyed by its own feature name (an attrset, so multiple features merge by key), and modules/defaults/nixos.nix adds them to isAdmin-enabled users; a feature must not assign users.users.extraGroups directly.
ratified: 72aa4a3e0235
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

extraGroups is internal and attrset-keyed for the same reason flakeCache.required is: last-wins
assignment from two features would silently drop one group set. The defaults module reads
config.extraGroups once, host-wide, and adds wheel plus those groups to admins only.

users.users is unavailable in standalone Home Manager modules, so feature-options.nix warns when
extraGroups is declared there — and warnings fail the build (modules/warnings-gate.nix).
