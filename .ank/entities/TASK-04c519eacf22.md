---
id: TASK-04c519eacf22
type: task
slug: give-the-three-uncovered-features-a-host-that-as
title: Give the three uncovered features a host that asks for them
created: 2026-11-04T17:01:56Z
author: josh@methyl-bazzite
status: done
scope:
  - hosts/methyl-base/base.nix
  - tests/configs.nix
  - tests/home.nix
blocked_by: []
done_criteria: |
  nixos-zram, hm-dcal and hm-ghostty are each enabled by a host or a fixture host, and tests/configs.nix / tests/home.nix assert the effect each produces (a zram swap unit, dcal on PATH, a wrapped ghostty package) rather than an enable flag.
criteria_by: creator
proof:
  - type: commit
    ref: c9c9a78
    criteria: 4ec171ed0903
    via: submitted
schema: 4
version: 2
---

TEST_DESIGN: 37 of 40 features are enabled by at least one host; nixos-zram is commented out in
hosts/methyl-base/base.nix, hm-dcal is listed nowhere, and hm-ghostty only appears in fixture
configs. Their advice is to cover them by enabling on a fixture host, not by isolating the module.

A feature no host asks for is not a shipping contract, so this task is only worth doing for the ones
that are about to become load-bearing — decide per feature and say so in the log rather than enabling
three hosts for coverage alone.
