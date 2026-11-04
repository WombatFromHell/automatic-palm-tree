---
id: TASK-604aab196ac8
type: task
slug: bootstrap-sh-resolves-the-nix-profile-it-puts-on
title: bootstrap.sh resolves the Nix profile it puts on PATH
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: open
scope:
  - bootstrap.sh
  - tests/bootstrap.bats
blocked_by: []
done_criteria: |
  bootstrap.sh --standalone --install <user>@<host> puts the profile nix actually installed on PATH before running home-manager, and tests/bootstrap.bats asserts both /home/josh/.nix-profile/bin and /home/josh/.local/state/nix/profile/bin against stubs.
criteria_by: creator
method: diagnose
schema: 4
version: 1
---

bootstrap.sh:93 assumes the classic profile path; newer Nix may use $XDG_STATE_HOME/nix/profile.
If the profile is elsewhere, home-manager is not on PATH after the channel install and the script
dies with "home-manager is not on PATH" on a box that is correctly installed.
