---
id: TASK-14b69ca0a0e2
type: task
slug: terraform-sh-the-shared-disk-partition-path-prov
title: "terraform.sh: the shared-disk partition path, proven on disk fixtures"
created: 2026-11-06T05:41:18Z
author: josh@methyl-bazzite
status: done
scope:
  - terraform.sh
  - install.sh
  - tests/terraform.bats
  - tests/disk-fixture.bash
  - tests/run.sh
  - flake.nix
blocked_by: []
done_criteria: |
  terraform.sh selects the ESP and root partition by index from sfdisk --json, formats a partition only
  where blkid reports no signature, adopts one that has a signature, refuses when the drive has no FAT
  ESP or a signature disagrees with the host's declared fsType or a blank target is declared by UUID,
  mounts the declared root under --root, and never runs wipefs, sfdisk --clear/--new/--change-name/
  --typecode, so the partition-table checksum is equal before and after every run. Each destructive
  step goes through the same confirm gate install.sh uses, and a run with no terminal is refused unless
  --force or INSTALL_FORCE=1. install.sh's terraform stage branches on ownsWholeDisk: true keeps the
  disko script, false calls ./terraform.sh, and the shared-drive refusal leaves resolve().
  bats tests/terraform.bats passes on sparse image fixtures with real mkfs/blkid/mtools and stubbed
  mount, covering bare-drive refusal, blank ESP+root adopt, Windows-shared byte parity (MSR + NTFS
  regions and both Microsoft boot files unchanged), Linux-shared parity (foreign loader and root data
  unchanged), non-vfat ESP refusal, and an idempotent rerun; bash tests/run.sh stays green and builds
  no derivation.
criteria_by: creator
verify: [gate]
method: tdd
proof:
  - type: test
    ref: local/bda259f5a70f@e40f6d9
    tree: scope/af17b80a32d6
    criteria: 2291289671f0
    verifier: gate@dc484de6fdb9
    via: verifier
schema: 4
version: 2
---
