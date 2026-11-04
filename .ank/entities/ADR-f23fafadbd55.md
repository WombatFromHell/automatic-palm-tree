---
id: ADR-f23fafadbd55
type: adr
slug: probe-enforced-by-on-a-let-binding
title: Daemon settings and cache settings are separate modules
created: 2026-11-04T16:45:42Z
author: josh@methyl-bazzite
status: accepted
scope:
  - modules/nix-settings.nix
  - modules/caches.nix
constraint: |
  modules/nix-settings.nix holds daemon settings only and modules/caches.nix owns substituters and public keys; nix.package stays lib.mkDefault there, because Home Manager asserts nix.package whenever nix.settings is used and a host must still be able to override it.
ratified: 9231cf8d78c5
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 4
---

modules/nix-settings.nix carries daemon behaviour (experimental-features, timeouts, download
attempts) and modules/caches.nix carries the registry's urls and keys. Splitting them is what
keeps the registry the single place a cache is written.

nix.package is lib.mkDefault, not a plain assignment: Home Manager strictly requires nix.package
when nix.settings is set, and a host that picks its own nix package must still win. A newcomer
who sets it plainly breaks that host override; one who drops it breaks every standalone Home
Manager build.
