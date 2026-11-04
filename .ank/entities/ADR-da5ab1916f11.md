---
id: ADR-da5ab1916f11
type: adr
slug: groups-are-published-per-feature-under-a-feature
title: Groups are published per feature under a feature-owned key
created: 2026-11-04T21:29:33Z
author: josh@methyl-bazzite
status: accepted
scope:
  - modules/feature-options.nix
  - modules/defaults/nixos.nix
  - features/**/*.nix
constraint: |
  A feature publishes groups through extraGroups under a stable key the feature owns - not necessarily its directory name - so features merge by key without clobbering one another, and modules/defaults/nixos.nix adds those groups to isAdmin-enabled users; a feature must not set users.users.extraGroups directly.
supersedes: ADR-0eff5dd992d8
ratified: ee25b562f154
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-04T21:48:41Z
schema: 4
version: 2
---

Retires ADR-0eff5dd992d8, whose demand that the key be the feature's own directory name still binds beside its amendment ADR-a79d6e562895 while one feature publishes a different key. The amendment stays accepted and states this rule correctly; this entity carries the same rule so the superseded wording stops binding. --supersedes names one document, and edit cannot repoint it, so the pair cannot be retired by a single entity; retiring the amendment too would add a second binding copy of the same rule.

Measured: features/nixos-automounts/nixos.nix:56 publishes extraGroups.filesystems = ["nas"]. The other publishers use their own name - extraGroups.qemu (nixos-qemu/nixos.nix:38), extraGroups.podman (nixos-podman/nixos.nix:34), extraGroups.kait2en (nixos-kait2en/nixos.nix:91) - so the four keys are distinct and modules/defaults/nixos.nix:8 concatenates them and hands them to isAdmin users at :28-31 without clobbering.

What the rule protects is key ownership, not key naming: modules/feature-options.nix declares extraGroups per feature and warns at :19-20 when a standalone home-manager module sets users.users directly, which is the case that would clobber. Nothing asserts a key name today (tests/configs.nix asserts the wheel group only), and renaming the key to nixos-automounts would rename the group users receive for no behaviour gain; that alternative was left unrun.
