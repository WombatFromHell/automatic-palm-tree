---
id: TASK-ebfd99fcecfb
type: task
slug: disko-input-nixos-disko-feature-and-the-drive-ow
title: Disko input, nixos-disko feature, and the drive-ownership guard
created: 2026-11-05T20:30:30Z
author: josh@methyl-bazzite
status: done
scope:
  - flake.nix
  - lib/default.nix
  - features/nixos-disko/nixos.nix
  - tests/disko.nix
  - tests/suite.nix
  - lib/host-options.nix
  - tests/support.nix
blocked_by: [TASK-2a954f7519dc]
done_criteria: |
  bash tests/run.sh passes with tests/disko.nix listed in tests/suite.nix parts: an attribute fails when a host whose config.flakeHost.ownsWholeDisk is false declares disk content.type = "gpt" and passes when it is true, a host without the nixos-disko feature keeps fsLib-built fileSystems (tests/filesystems.nix and tests/mounts.nix keep passing), lib/host-options.nix declares ownsWholeDisk defaulting to false, inputs.disko is pinned without follows and features/nixos-disko/nixos.nix imports inputs.disko.nixosModules.disko, and nix run .#apps.x86_64-linux.style reports no findings.
criteria_by: creator
verify: [gate]
method: tdd
proof:
  - type: test
    ref: local/cfa3dcd29daf@a377dfa
    tree: scope/6b0e05aa90b2
    criteria: 9b4fe6e7ecfb
    verifier: gate@dc484de6fdb9
    via: verifier
schema: 4
version: 3
---

The guard is the part worth building first: it costs nothing at eval and makes the destructive shape impossible before any host declares a layout. It is a module assertion in the feature module, read back as a nix-unit attribute through tests/support.nix's bareEval and failingAssertions, the way tests/caches.nix reads modules/caches.nix.

The feature module is where an external NixOS module gets imported, following features/nixos-kait2en/nixos.nix:38. Host files stay records (ADR-5c64), so a layout is never a host attribute; it arrives as a host module.
