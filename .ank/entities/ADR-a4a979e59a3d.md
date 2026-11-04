---
id: ADR-a4a979e59a3d
type: adr
slug: feature-module-files-are-named-after-the-platfor
title: Feature module files are named after the platform
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: superseded
scope:
  - features/*/nixos.nix
  - features/*/home.nix
  - features/*/_overlays.nix
  - lib/features.nix
constraint: |
  A feature contributes modules only through features/<name>/nixos.nix, home.nix and _overlays.nix; every other file in a feature directory is not a module, and a feature listed for a platform that has no matching file contributes nothing.
enforced_by:
  - lib/features.nix#resolveFeaturePaths
ratified: 28a086bba332
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T18:06:15Z
schema: 4
version: 3
---

knownFiles is the whole list of module file names: nixos, home, _overlays. _overlays.nix is a
module because it sets nixpkgs.overlays, which lets an overlay be gated on a feature option
instead of frozen at package-set build time. Discovery only accepts regular files and symlinks,
so a symlinked feature checkout loads.

A feature directory whose module is named default.nix or nixos-default.nix evaluates to nothing
and the host silently gets no feature.
