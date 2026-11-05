---
id: TASK-97a9e3eadea3
type: task
slug: eval-suites-run-as-nix-unit-test-attributes-in-o
title: Eval suites run as nix-unit test attributes in one scoped invocation
created: 2026-11-05T02:31:52Z
author: nix-unit-suite
status: open
scope:
  - tests/suite.nix
  - tests/filesystems.nix
  - tests/pins.nix
  - tests/caches.nix
  - tests/warnings.nix
  - tests/zram.nix
  - tests/loader.nix
  - tests/run.sh
  - lib/default.nix
blocked_by: [TASK-40d9c6b2cc7c]
done_criteria: |
  bash tests/run.sh exits 0 and the merged invocation reports a peak under the 1792MB cap.
criteria_by: creator
verify: [gate]
method: tdd
schema: 4
version: 1
---

PLAN-nix-unit.md S1-S3. Verified against the binary: --flake and file arguments both work, --impure is required because tests/support.nix calls builtins.getFlake, expectedError needs msg or type (msg alone is accepted), an empty attrset prints 0/0 and exits 0, and difftastic is inside the package wrapper.

Red before green: add the gate step before the attrsets exist so it fails, then convert. Checkpoint is the merged run's peak and wall, measured, not assumed: separate runs of the six cheap suites cost ~7s and 551MB, one process ~2.6s and 582MB.

nix-unit 2.34.2 evaluates with libnix 2.34 while the host nix is 2.35.4; if a suite disagrees, that is a finding to log here, not a reason to soften the criterion.
