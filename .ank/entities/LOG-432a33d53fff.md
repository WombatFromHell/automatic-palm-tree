---
id: LOG-432a33d53fff
type: log
title: "VM run on nixos@192.168.1.237 (nixos-minimal ISO, 7.8G RAM, 30G nvme0n1): the flake was rsynced in"
created: 2026-11-08T02:56:22Z
author: josh@methyl-bazzite
scope:
  - hosts/methyl-nixos/**
  - features/nixos-disko/**
  - flake.nix
  - tests/configs.nix
  - tests/disko.nix
about: TASK-8364b000c9e9
seq: 1
schema: 4
version: 1
---

 place (4.4M, no .git). 'install.sh --force --stage prepare methyl-nixos' exited 0 and left the partition table byte-identical (08f516fe6038d736864b1bd9da787240), with a 2GB zram added for the eval. 'install.sh --stage terraform methyl-nixos' first refused: /dev/nvme0n1p2 held ext4 labelled nixos, a filesystem no entry of the recipe claims — the guard from ADR-b77ec913151f working, not a bug. That drive held leftovers of an earlier half-deploy, so the operator authorised blanking it as harness setup (wipefs -a on p1/p2, sfdisk --delete 1 2, wipefs -a on the drive); the drive then carried no signature at all, and terraform.sh built the layout itself, no hand partitioning. 'install.sh --force --stage terraform methyl-nixos' exited 0: gpt with esp p1 512M vfat labelled boot and p2 29.5G btrfs labelled nixos reaching the end of usable space, /mnt mounted from /dev/nvme0n1p2[/@]. 'terraform.sh --verify --recipe hosts/methyl-nixos/terraform.json --disk /dev/nvme0n1 --mount /mnt' exited 0 printing 'recipe satisfied on /dev/nvme0n1'. No closure was built: the terraform stage runs terraform.sh only, so this needed no multi-gig image.
