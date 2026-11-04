---
id: ADR-a6c73e1ae002
type: adr
slug: pkgs-unstable-is-a-member-of-the-set-and-never-r
title: pkgs.unstable is a member of the set, and never reads itself
created: 2026-11-04T21:29:33Z
author: josh@methyl-bazzite
status: proposed
scope:
  - lib/default.nix
  - features/**/*.nix
  - hosts/**/*.nix
constraint: |
  pkgs.unstable is built from nixpkgs-unstable with baseOverlay only; unstable code takes packages from the set above it as pkgs.unstable.flakePackages.<name>, and `with pkgs.unstable` is allowed because it only brings those members into scope, while the unstable set must never read or force itself.
enforced_by:
  - lib/default.nix#unstableFor
supersedes: ADR-559bfe76f766
schema: 4
version: 2
---

Retires ADR-559bfe76f766, whose wording two hosts contradict today: the old text reads "read members as pkgs.unstable.<name> rather than pkgs.unstable itself". Its amendment ADR-361112a1df8e stays accepted and states this rule correctly, so this entity carries the same rule so the superseded wording stops binding. --supersedes names one document, and edit cannot repoint it, so the pair cannot be retired by a single entity; retiring the amendment too would add a second binding copy of the same rule.

Measured: hosts/methyl/home-josh.nix:2 and hosts/methyl-nixos/home-josh.nix:2 open with `with pkgs.unstable`; their bodies still reach packages through members of that set, so the with-binding is scope sugar over the set, not the set reading itself. lib/default.nix:50 builds unstableFor from nixpkgs-unstable with baseOverlay only, and lib/default.nix:66 injects it as the `unstable` member of the set above.

The thing the rule protects is the self-read: a set that asks for itself deadlocks or double-evaluates. Forbidding the with-binding would only force a name prefix on every reference while leaving a real self-read possible. The prohibition is carried forward verbatim in the constraint above, so retiring the stale document loses no coverage.
