---
id: ADR-ba1f50547dd4
type: adr
slug: the-two-url-expanders-must-stay-byte-identical
title: The two URL expanders must stay byte-identical
created: 2026-11-04T16:49:26Z
author: josh@methyl-bazzite
status: accepted
scope:
  - lib/updater.sh
  - lib/pin-meta.nix
  - tests/run.sh
  - features/*/metadata.json
constraint: |
  lib/updater.sh render_url and lib/pin-meta.nix releaseAsset must expand {repo}, {version} and {arch} to the same URL for every pin and system; tests/run.sh diffs them byte-for-byte, so a change to one requires the change to the other.
enforced_by:
  - lib/pin-meta.nix#releaseAsset
ratified: a27bcbfa5aa7
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T18:06:15Z
schema: 4
version: 2
---

The two live in different runtimes and cannot share code: bash expands the template at fetch time,
Nix at eval time. If they drift, the hash the updater pinned no longer matches the URL Nix builds,
and the failure shows up as a build-time hash mismatch far from the cause.

A missing arches entry renders an empty token in bash (so fetch_hash fails at the URL) while the
Nix side throws at eval; the parity check is what keeps the two honest.
