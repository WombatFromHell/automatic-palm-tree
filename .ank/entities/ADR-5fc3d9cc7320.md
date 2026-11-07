---
id: ADR-5fc3d9cc7320
type: adr
slug: test-fixtures-are-plain-factories-in-the-files-t
title: Test fixtures are plain factories in the files that own them, and the gate counts assertions
created: 2026-11-07T21:50:06Z
author: josh@methyl-bazzite
status: proposed
scope:
  - tests/helpers.bash
  - tests/disk-fixture.bash
  - tests/support.nix
  - tests/suite-ledger.txt
  - tests/*.nix
  - tests/*.bats
  - tests/run.sh
constraint: |
  A shared test fixture is a plain function in tests/helpers.bash, tests/disk-fixture.bash or tests/support.nix, never a registry, a config file or a framework, and it ships only when it removes three or more call sites; a function added to tests/support.nix forces nothing at definition time and must not raise any suite's measured scope peak; fixture content costing more than about 50ms per test is built once in a bats setup_file and copied per test; a fixture never imports repo modules, never names the script under test, never branches on being a fixture, and never asserts an implementation string, so a derivation's buildCommand is read only to prove what a build produced; adding a scenario costs one factory call plus one assertion; every gate verdict line reports its assertion count and a count below the floor in tests/suite-ledger.txt fails the gate rather than printing ok.
schema: 4
version: 1
---
The suite is duplicated in two places, and both are measured, not guessed.

Bash: `tests/terraform.bats` runs 58 tests through a ritual of 100 `disk` calls, 47 `stub_lsblk`
calls, 41 `recipe_file` calls and 30 hand-written before/after checksum pairs. `sgdisk` costs ~1.01s
per image whatever the partition count, and `ssh-keygen` plus a pty runner cost ~150ms inside a
`sopsctl.bats` test body. So the duplication is not cosmetic: it is ~12.6s of a 17.2s tier and
~150ms times 62 tests in another.

Nix: four suites re-implement the same accessors instead of sharing them — `cfg = h:
...nixosConfigurations.${h.name}.config` twice, `homeCfg`/`pkgOf` three times, seven wrappers in
`configs.nix`, `installed` and `fxInstalled` as literal twins in `home.nix`, and the derivation-body
readers (`drvAttrs.buildCommand`, `drvAttrs.installPhase`) written out in `wrap.nix` and again inline
in the four build suites. `TASK-40d9c6b2cc7c` already landed one bare-eval factory, one package
predicate and collapsed mount factories; this ADR is the rest of the same rule, stated once so the
next audit does not have to rediscover it.

The count rule exists because a fixture refactor is exactly the change that can silently lose an
assertion. Today the gate prints `ok <suite>` with no count, so "the factory now proves the same
thing" is a claim a human eyeballs. The floors are the measured baseline: 301 bats tests, 536
assertions, 176 nix-unit attributes, 80 ck-tier checks. A shortfall is a `FAIL`, not a comment. This
carries the vacuous-pass rule of ADR-fb331caa521d one level up: a suite contributes checks, and the
tier that contributes none fails.

Rejected, and rejected on measurement:

- A shared `nix` stub. The six suites stub `nix` with six different behaviors — daemon probe,
  `path-info`, `attrNames`, host-fact eval, `--out-link` materialization, cwd recording. One factory
  with mode flags is a mega-stub that reads worse than six small ones.
- Merging the four fixture builds into one `nix build`. The suite audit rejected it ("no shared
  >=5-line block once read"); a merged `symlinkJoin` loses per-suite failure isolation to save ~3
  process startups.
- A fixture registry or config file. A second way to name the same thing, and the memory convention
  in ADR-7d6e8fedf8a7 means the shared eval graph must stay small, not become discoverable.

Consequences someone editing the suite has to live with:

- `tests/support.nix` grows, but only with pure functions. Anything that forces a value at definition
  time is paid by every suite process, so peaks (home 1019MB, configs ~756MB, wrap 736MB, builds
  <=418MB) are checked from the gate's own telemetry lines rather than assumed.
- Floors ratchet up only. Adding a scenario raises a floor; deleting one is a deliberate edit to
  `tests/suite-ledger.txt`, which shows up in the diff.
- Hoisted fixture content is a template directory. A test may mutate its own copy, never the
  template, or the next test in the file inherits the damage.
- `entries_json` stops swallowing `sfdisk` failure. A drive with no partition table currently reads
  as `""`, which makes a byte-identity assertion pass on a wiped GPT; with the failure surfaced, that
  run goes red. That is the ADR-b77ec913151f claim the byte tier exists to prove.
