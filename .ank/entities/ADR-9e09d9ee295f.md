---
id: ADR-9e09d9ee295f
type: adr
slug: modules-merge-by-first-occurrence-and-mkforce-wi
title: Modules merge by first occurrence and mkForce wins on scalars
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - lib/host-lib.nix
  - hosts/**/*.nix
constraint: |
  Host and profile composition goes through hostLib.mergeModules and mergeHome, which union lists by first occurrence and let mkForce win on scalars; module lists are never merged with //, because lib.unique only removes consecutive duplicates and a profile reached twice would redeclare options.
enforced_by:
  - lib/host-lib.nix#mergeModules
ratified: 1a0da404f235
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

mergeValue treats module-system wrappers and derivations as leaves, merges attrsets recursively,
and folds lists with lib.elem so a feature reached through two profile paths is listed once. The
module system rejects a second declaration of the same option, so dedup happens here rather than
in nixpkgs.

A newcomer composing profiles with // loses the left-hand feature list and re-imports modules
twice. That is the break this decision forbids.
