#!/usr/bin/env bats
# tests/floors.sh: the assertion floors the gate holds every suite to. Source counts only — no
# eval, no build — so this guard costs ~0MB and belongs in the stub tier. The floors themselves are
# data in tests/suite-ledger.txt and ratchet up only; deleting a check is a deliberate edit there.
load helpers

floors() { TESTS_DIR="$1" LEDGER="$2" bash "$repo/tests/floors.sh"; }

@test "floors.sh reports every suite count from the ledger" {
  run floors "$repo/tests" "$repo/tests/suite-ledger.txt"
  [ "$status" = 0 ]
  assert_out "tests/home.nix checks 21"
  assert_out "tests/terraform.bats assert 157"
  assert_out "tests/filesystems.nix attrs 56"
}

@test "a deleted assertion turns the floors red" {
  mkdir -p "$stubs/t"
  cp "$repo/tests/terraform.bats" "$stubs/t/"
  awk 'n < 1 && /assert_/ { n++; next } { print }' "$repo/tests/terraform.bats" >"$stubs/t/terraform.bats"
  printf 'tests/terraform.bats assert 157\n' >"$stubs/t/ledger.txt"
  run floors "$stubs/t" "$stubs/t/ledger.txt"
  [ "$status" = 1 ]
  assert_out "FAIL tests/terraform.bats assert floor=157 count=156"
}

@test "a ledger entry for a suite that no longer exists fails loudly" {
  mkdir -p "$stubs/t"
  printf 'tests/gone.bats assert 4\n' >"$stubs/t/ledger.txt"
  run floors "$stubs/t" "$stubs/t/ledger.txt"
  [ "$status" = 1 ]
  assert_out "FAIL tests/gone.bats [no such suite]"
}

@test "a new suite with assertions cannot slip in unfloored" {
  mkdir -p "$stubs/t"
  printf '@test "x" { assert_out "a"; }\n' >"$stubs/t/new.bats"
  printf 'tests/home.nix checks 21\n' >"$stubs/t/ledger.txt"
  run floors "$stubs/t" "$stubs/t/ledger.txt"
  [ "$status" = 1 ]
  assert_out "FAIL tests/new.bats [unfloored]"
}

@test "the real ledger floors the real suite tree" {
  run bash "$repo/tests/floors.sh"
  [ "$status" = 0 ]
}
