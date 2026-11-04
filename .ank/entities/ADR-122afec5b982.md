---
id: ADR-122afec5b982
type: adr
slug: features-name-update-sh-is-a-symlink-to-lib-upda
title: features/<name>/update.sh is a symlink to lib/updater.sh
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - features/*/update.sh
  - lib/updater.sh
  - update-all.sh
constraint: |
  Every feature updater is a symlink to lib/updater.sh, scaffolded by lib/updater.sh --install features/<name>; update-all.sh refuses a copy, because a copy runs fine and then drifts silently from the shared updater.
ratified: 6424a520c663
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T18:06:15Z
schema: 4
version: 2
---

The CLI contract is identical for every feature: no arg updates to latest and verifies a "none"
pin, --check exits 0 when current and 1 when an update is available or the pin moved, <ref> pins
explicitly and refreshes hashes. All feature-specific config lives in metadata.json.

Prefetch happens before metadata.json is written, so a failed fetch leaves the pin intact;
meta_set rewrites through a temp file. tests/pins.nix pins the symlink itself.
