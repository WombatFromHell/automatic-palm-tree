---
id: ADR-ca72f792db52
type: adr
slug: install-sh-is-read-only-until-the-operator-says
title: install.sh is read-only until the operator says yes
created: 2026-11-05T20:30:08Z
author: josh@methyl-bazzite
status: proposed
scope:
  - bootstrap.sh
  - tests/bootstrap.bats
  - DESIGN.md
constraint: |
  install.sh follows the standard non-graphical install-ISO workflow, brings the flake onto the target by git clone (falling back to nix-shell -p git) or a file transfer, prints a read-only plan before touching anything, and prompts for explicit confirmation before any format, mount, or nixos-install step.
schema: 4
version: 2
---

bootstrap.sh is the rebuild path for a host that already runs NixOS; an install is a different perimeter, so install.sh is a separate script rather than a flag bolted onto it. It runs on the target inside the non-graphical install ISO, where the repo is fetched by git clone or scp/sftp and evaluated by the ISO's own nix (flakes enabled, no nix-daemon), so every evaluation and build it runs sits inside a systemd-run --user --scope MemoryMax bound, the same bound DESIGN.md's Build RAM section holds for bootstrap.sh.

Read-only first is the contract: the partition table and disko's dry-run are printed, and only then does anything ask. A confirmation is required per destructive step, not once for the whole run, because the step that wipes a partition table and the step that formats a filesystem are different decisions. An existing Linux filesystem may be reformatted after that prompt; a partition Windows owns is never a target, and resizing one is not offered.

--remote delegates to nixos-anywhere with --phases disko,install --build-on local so evaluation and build happen on the calling host rather than on the ISO; its default disko mode is destroy, so the delegation passes the non-destructive mode explicitly and never inherits the default.
