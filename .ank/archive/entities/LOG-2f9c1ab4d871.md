---
id: LOG-2f9c1ab4d871
type: log
title: "R6 append landed: free-space placement proven on the fixture tier, 41/41 terraform.bats green."
created: 2026-11-06T21:40:00Z
author: josh@methyl-bottle
scope:
  - terraform.sh
  - tests/terraform.bats
  - tests/disk-fixture.bash
  - tests/deploy-loop.sh
about: TASK-c866dfd7975e
seq: 8
schema: 4
version: 1
---

An entry that matches nothing in shared mode is now laid into the first 1MiB-aligned gap large enough and appended with `sfdisk --append` (explicit start/size/type/name), then adopted if it already holds a filesystem and formatted if blank. Free-space maths is settled before any write: a size no gap holds, `rest` with nothing left, an unreadable size and two entries wanting one partition all exit 2 with the drive byte-identical. Gaps are read from the table and capped at the last aligned sector before the backup GPT header, so an append can never overwrite it. An append needs the confirm gate (`--force` only), and the entries that existed before are compared sector-for-sector afterwards, so a moved partition is a failure rather than a side effect. Discovery matches a drive the recipe would *append* into, not only one it would adopt: `drive_matches` runs the same `resolve_entries` the run uses, and `held` no longer refuses, because an unresolved entry is placed in free space instead of ever formatting somebody else's partition.

Fixture tier: 41/41 (`bats tests/terraform.bats`, 21s), full gate green (`bash tests/run.sh`, 19 suites + expander parity + shellcheck). New coverage: append creates the node and formats it; append is refused without --force; append lands at the exact gap boundary; 34M fits and 35M refuses on two copies of the same drive; two entries claiming one partition refuse; a drive with no free space refuses; append survives an unrelated pre-existing gap; a tableless drive refuses with zero bytes written. Test 24's `assert_no_call "sfdisk"` was wrong -- shared mode must *read* the table with `sfdisk --json`; it now asserts the write form `sfdisk -X gpt` is never used, and test 20 runs its append on a second copy of the drive because appending changes the drive its sibling run reads.

Real-device gap: `tests/deploy-loop.sh` gains step 11, an append on a loop device (ESP + Linux partition + free space, one recipe entry nothing describes) asserting a third entry appears, the first two entries are unchanged JSON, and the new partition holds ext4 labelled `nixos` and is the real mount source. It cannot be run here without a password; run `sudo nix develop --command bash tests/deploy-loop.sh`.
