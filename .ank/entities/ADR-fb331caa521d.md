---
id: ADR-fb331caa521d
type: adr
slug: eval-tier-assertions-are-nix-unit-test-attribute
title: Eval-tier assertions are nix-unit test attributes, run in one scoped invocation
created: 2026-11-05T02:31:01Z
author: nix-unit-suite
status: proposed
scope:
  - tests/*.nix
  - tests/run.sh
constraint: |
  An eval-tier assertion is a test* attribute of a suite attrset run by nix-unit, compared with expr/expected or expectedError.msg for a must-throw check; builtins.tryEval must never stand in for one and tests/red/*.nix guards must not exist, the merged suites run in one scoped nix-unit invocation through tests/nix-eval.sh, and a suite that contributes no test* attribute must fail the gate rather than pass vacuously.
supersedes: ADR-6d64e5609b7c
schema: 4
version: 1
---

The gate today runs 37 nix processes, 16 of them tests/red guards at ~0.45s each (measured: red tier 7s, whole gate ~44s). nix-unit gives per-test failure isolation with a trace and a real diff, and its expectedError attribute covers the must-throw contract the guards cover, so the guard files, the '# expect:' marker the gate parses (run.sh:237) and the guard loop all go away.

Measured on this machine, warm store, cap 1792MB: the six cheap suites cost ~7s and 551MB across six process startups; forced through one process they cost ~2.6s and 582MB. So merging them is a perf win, not a cosmetic one.

What does NOT move: configs.nix, home.nix, mounts.nix, wrap.nix and outputs.nix. nix-unit forceValueDeep forces both expr and expected deep, which is far more than the targeted option reads those suites do today (configs.nix per host peaks 650-744MB, home.nix 965MB, wrap.nix 709MB, naming flake outputs measured 2.2GB). Putting a host config or an output attrset in expr would break the cap that ADR-7d6e8fedf8a7 exists to hold, and would be unbounded inside a build. So ck/suite stay for that tier.

The tryEval clause is carried unchanged: builtins.tryEval cannot gate a deferred error in this Nix, so it must never stand in for an assertion. expectedError carries msg only (a regex); type is optional and our throws are TypeError and ThrownError, so pinning types is churn.

Vacuousness is the new failure mode: a suite whose attributes do not start with test contributes nothing and nix-unit exits 0 with 0/0 (verified against the binary). The constraint therefore names a guard test rather than trusting the count.

ADR-dcf30409fc01 stays accepted and amends ADR-5eb78b01a869; --supersedes takes one id, so it cannot be retired by this entity. Its scope is tests/red/*.nix and tests/run.sh; once tests/red/ is deleted its first glob matches nothing and ank review reports the scope gone dead, which is the path that retires it. Retiring it with a second successor would add a second binding copy of the same rule, which is why ADR-6d64e5609b7c declined to do that.
