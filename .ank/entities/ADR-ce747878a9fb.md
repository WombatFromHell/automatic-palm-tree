---
id: ADR-ce747878a9fb
type: adr
slug: nixgl-supplies-gpu-drivers-only-where-the-host-h
title: nixGL supplies GPU drivers only where the host has none
created: 2026-11-04T16:49:27Z
author: josh@methyl-bazzite
status: accepted
scope:
  - features/hm-nixgl/home.nix
  - modules/defaults/home-manager.nix
  - features/**/*.nix
constraint: |
  targets.genericLinux.nixGL.packages is lib.mkIf on !config.flakeHost.isNixOS, feature code wraps GPU applications with lib.nixGL.wrapGpu rather than config.lib.nixGL.wrap, and features.nixgl.wrapper stays exactly Home Manager's enum (mesa, mesaPrime, nvidia, nvidiaPrime).
ratified: 88ee7fcb8122
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

Setting packages on a NixOS host pulls foreign Mesa into the system closure, so packages is null
there and wrapGpu is a no-op. Home Manager's own lib.nixGL.wrap only exists when the genericLinux
target is on and is a no-op when packages is null, so every feature calls wrapGpu instead — and a
NixOS host gets its package as-is.

defaultWrapper still follows the host's choice, which is what makes Home Manager pick the right
driver set. The Nvidia wrappers require the configuration to be built with --impure.
