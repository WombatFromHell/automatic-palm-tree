---
id: ADR-f1ad2a9d4ff1
type: adr
slug: flake-inputs-and-fslib-arrive-through-specialarg
title: Flake inputs and fsLib arrive through specialArgs, never by import
created: 2026-11-04T16:49:27Z
author: josh@methyl-bazzite
status: accepted
scope:
  - lib/builders.nix
  - hosts/**/hardware-configuration.nix
  - features/**/*.nix
constraint: |
  Module code takes flake inputs and fsLib from specialArgs and must not import lib/filesystems.nix or reach flake inputs directly, because a hand-regenerated hardware-configuration.nix resolves only what the builder hands it.
enforced_by:
  - lib/builders.nix#inputArgs
ratified: a55dc6a98483
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

inputArgs is the same record for nixosSystem, the Home Manager integration and standalone home
configs. fsLib is injected rather than imported so the hand-edited hardware-configuration.nix
still resolves it after nixos-generate-config regenerates the file — a file whose content is
regenerated cannot resolve a relative import the way a module in this tree does.

A feature module importing ../lib/filesystems.nix would work in-tree and fail wherever the host
file is regenerated or symlinked.
