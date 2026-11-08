#!/usr/bin/env bats
# tests/run.sh must not report a skipped tier as a pass in CI: a tier whose tool is absent there is
# a coverage loss, not a green run. Stubbed PATH carries none of the tier tools, so the gate runs its
# skip branches only -- ~1s, no eval, no build.
load helpers

@test "CI turns a missing tier tool into a failure" {
  run env CI=1 PATH="$stubs:/usr/bin:/bin" bash "$repo/tests/run.sh"
  [ "$status" != 0 ]
  assert_out "FAIL bats suites [bats not installed]"
  assert_out "FAIL tests/suite.nix [nix-unit not in the devShell]"
}

@test "locally the same tier is reported as a skip" {
  run env -u CI PATH="$stubs:/usr/bin:/bin" bash "$repo/tests/run.sh"
  assert_out "skip bats suites [bats not installed]"
  assert_out "skip tests/suite.nix [nix-unit not in the devShell]"
}

# The VM tier boots a guest on this machine, so it must never join the eval gate: a suite listed in
# run.sh would boot a VM inside a gate whose whole point is that it only evaluates.
@test "a VM tier suite cannot join the eval gate" {
  local gated="$BATS_TMPDIR/run-with-vm-tier.sh"
  sed 's|tests/nix-eval.bats)|tests/nix-eval.bats tests/vm-check.bats)|' "$repo/tests/run.sh" >"$gated"
  run env CI=1 PATH="$stubs:/usr/bin:/bin" bash "$gated"
  assert_out "FAIL tests/vm-check.bats [the VM tier runs separately, not in this gate]"
  rm -f "$gated"
}
