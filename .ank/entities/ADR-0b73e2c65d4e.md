---
id: ADR-0b73e2c65d4e
type: adr
slug: metadata-json-is-the-pin-contract-and-derivation
title: metadata.json is the pin contract and derivations read it through pinMeta
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - features/*/metadata.json
  - features/*/_package.nix
  - lib/pin-meta.nix
  - lib/updater.sh
constraint: |
  A pinned derivation reads its metadata.json through the pinMeta package member and lib/pin-meta.nix (releaseAsset, gitSource, pinnedSystems); repo, kind, strategy, url ({repo} {version} {arch}), arches, version and hashes are the contract, and no feature may re-implement the template or the hash lookup.
enforced_by:
  - lib/pin-meta.nix#releaseAsset
ratified: 397c2eff5013
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:50:56Z
schema: 4
version: 2
---

pinMeta is injected into every package set, so a derivation takes the contract like any build
dependency. pinnedSystems checks arches and hashes describe the same systems on every resolution,
so a malformed pin names the offending key instead of surfacing as an unrelated nixpkgs
platform error; meta.platforms is pinnedSystems pin.

arches is lazy on purpose: releaseAsset throws only when {arch} is in the template, which lets a
single-arch pin with no arches key (hm-tmux) still resolve.
