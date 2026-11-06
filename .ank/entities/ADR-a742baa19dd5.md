---
id: ADR-a742baa19dd5
type: adr
slug: a-host-fact-names-the-consequence-it-controls
title: A host fact names the consequence it controls
created: 2026-11-05T20:36:56Z
author: josh@methyl-bazzite
status: proposed
scope:
  - lib/host-options.nix
  - modules/host-facts.nix
  - tests/support.nix
  - features/nixos-kde/nixos.nix
  - hosts/methyl-base/core.nix
constraint: |
  Every fact in lib/host-options.nix is named for the behaviour it changes, so a host file says what setting it does; a fact whose value changes nothing is deleted rather than kept for later, which retires isQemuVM.
schema: 4
version: 1
---

isQemuVM is a label, not a consequence. Its two readers are features/nixos-kde/nixos.nix:15 and :18, where it picks xserver.enable and sddm.wayland.enable — the fact actually means "this display has no GPU, so prefer X11", and nothing else reads it. hosts/methyl-base/core.nix:4 sets it false and no host ever sets it true, so the mkIf is constant today: deleting both lines leaves xserver.enable at its default false and sddm.wayland.enable at nixpkgs' default true, which is exactly what every host evaluates now.

A fact that means what it says is what the ownership decision needs instead: ownsWholeDisk, whose value decides whether a layout may partition the whole drive, and which methyl-nixos sets true while methyl and propyl leave it false because a Windows install shares their disk.
