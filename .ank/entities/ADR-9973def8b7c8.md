---
id: ADR-9973def8b7c8
type: adr
slug: host-facts-travel-as-config-flakehost
title: Host facts travel as config.flakeHost
created: 2026-11-04T16:49:27Z
author: josh@methyl-bazzite
status: accepted
scope:
  - modules/host-facts.nix
  - lib/host-options.nix
  - lib/builders.nix
  - features/**/*.nix
constraint: |
  Modules read host facts through config.flakeHost, typed with flakeHostOptions and set once by mkHostFactsModule; the derived options keep no default so a builder that forgets one fails loudly, and a host file may not set them.
enforced_by:
  - lib/host-options.nix#flakeHostOptions
ratified: 2df90c5335e4
verified:
  - by: WombatFromHell@users.noreply.github.com
    at: 2026-11-04T17:51:02Z
schema: 4
version: 2
---

The schema is split by ownership: hostFacts (what a host declares), authoringOptions (what it
wires in), derivedOptions (owned by discovery and the builders). hostOptions is what a host file
is validated against; flakeHostOptions is what config.flakeHost is typed with, so groups replace
the subtract-list that used to have to stay in step with it.

mkHostFactsModule narrows the record with lib.getAttrs: a fact the schema declares but the record
lacks is a loud missing-attribute error, an extra attribute is ignored. Admin usernames are derived
once in enrichHost so host-facts and the NixOS user defaults read the same list.
