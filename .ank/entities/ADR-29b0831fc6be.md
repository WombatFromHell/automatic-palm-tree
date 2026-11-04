---
id: ADR-29b0831fc6be
type: adr
slug: the-cache-registry-is-the-only-place-a-cache-is
title: The cache registry is the only place a cache is written; gating reads the registry
created: 2026-11-04T21:29:33Z
author: josh@methyl-bazzite
status: proposed
scope:
  - modules/cache-registry.nix
  - modules/caches.nix
  - features/**/*.nix
constraint: |
  modules/cache-registry.nix is the only place a substituter url or public key appears; a feature names the cache it needs through flakeCache.required.<name> rather than declaring a cache of its own, and gating reads the registry - config.flakeCache.enable membership where a feature needs one specific cache, config.flakeCache.ready where it needs every required one - never a hand-flipped bootstrap flag.
enforced_by:
  - modules/caches.nix#requiredNames
supersedes: ADR-844789f84321
schema: 4
version: 1
---

Retires ADR-844789f84321, whose "gating reads config.flakeCache.ready" still binds beside its amendment ADR-549e856f8e4e while two features gate on membership. The amendment stays accepted and states this rule correctly; this entity carries the same rule so the superseded wording stops binding. --supersedes names one document, and edit cannot repoint it, so the pair cannot be retired by a single entity; retiring the amendment too would add a second binding copy of the same rule.

Measured: features/nixos-cachyos/nixos.nix:14 gates on lib.elem "nix-community" config.flakeCache.enable, features/nixos-niri/_spicy.nix:12 gates on lib.elem "wombatfromhell" config.flakeCache.enable, and both name their cache through flakeCache.required (nixos-cachyos/nixos.nix:13, nixos-niri/nixos.nix:29). features/nixos-kait2en uses flakeCache.ready, so both forms are live in the tree. modules/cache-registry.nix is the only file holding a url or a key, and modules/caches.nix:24-28 turns a required name absent from the registry into an assertion and a required cache not enabled into a warning - the single-writer rule is enforced there, unchanged.

ready answers "every cache this host requires is enabled", which is the wrong question for a feature that needs one specific cache: a host with cachyos enabled and another required cache missing is still usable for cachyos builds.
