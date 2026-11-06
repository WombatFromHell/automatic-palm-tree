---
id: LOG-38ae1e8cc5f8
type: log
title: "install.sh now acts on hosts/<host>/terraform.json: terraform runs --recipe, the recipe's owns must"
created: 2026-11-06T23:59:36Z
author: josh@methyl-bazzite
scope:
  - terraform.sh
  - install.sh
  - hosts/**
  - modules/terraform-recipe.nix
  - tests/terraform.bats
about: TASK-c866dfd7975e
seq: 9
schema: 4
version: 1
---

 equal flakeHost.ownsWholeDisk (a recipe claiming a host disko owns is refused, not ignored), and deploy re-reads the drive with terraform.sh --verify before nixos-install. install.bats 38/38, full gate green. Remaining criterion clause needs a real drive: an emitted recipe for methyl can only be written on methyl, which is unreachable from here.
