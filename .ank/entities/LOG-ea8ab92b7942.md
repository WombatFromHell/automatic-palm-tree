---
id: LOG-ea8ab92b7942
type: log
title: "methyl (ssh nixos@192.168.1.188) carries no recipe because its drive has nothing to read: /dev/vda"
created: 2026-11-07T00:15:46Z
author: josh@methyl-bazzite
scope:
  - terraform.sh
  - install.sh
  - hosts/**
  - modules/terraform-recipe.nix
  - tests/terraform.bats
about: TASK-c866dfd7975e
seq: 10
schema: 4
version: 1
---

 is tableless and signatureless, so terraform.sh --emit exits 2 and an owns=false recipe would be refused before any write. The criterion opens with "hosts/<host>/terraform.json declares the layout", and on methyl that needs owned mode — which install.sh still routes to disko for ownsWholeDisk=true hosts (resolve refuses a terraform.json on an owned host: "disko owns the layout (ADR-eaca61b85782), so hosts/<host>/terraform.json is never read — remove it"). That wiring is TASK-8364b000c9e9. terraform.sh itself stays proven: 41/41 terraform.bats, 10/10 tests/deploy-loop.sh on real loop devices.
