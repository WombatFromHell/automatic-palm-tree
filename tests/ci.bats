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
