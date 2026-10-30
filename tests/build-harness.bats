#!/usr/bin/env bats
# tests/build-harness.sh against a PATH stub: which `nix build` command it runs, what the telemetry
# line reports, and what it refuses. No real eval, no real build, no cache.
# Scoping itself is tests/nix-eval.sh's job (covered by the gate's own suites), so these run through
# the real nix-eval.sh with a stub `nix` on PATH — ~0MB, ~1s.

setup() {
  repo="$PWD"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : > "$calls"
  export CALLS="$calls"
  out="$stubs/out"
  mkdir -p "$out"

  # Quoted heredoc: the stub body must survive unevaluated (an unquoted heredoc expands `$((...))`
  # and `$i` when the file is written). `nix` records argv and answers `path-info` with a fake
  # recursive size.
  cat > "$stubs/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $* NIX_SHOW_STATS=${NIX_SHOW_STATS:-unset} NIX_CONFIG=${NIX_CONFIG:-unset}" >> "$CALLS"
if [ "$1" = path-info ]; then printf '/nix/store/fake 2.0 KiB 1.0 MiB\n'; exit 0; fi
exit ${NIX_EXIT:-0}
EOF
  chmod +x "$stubs/nix"
}

teardown() { rm -rf "$stubs"; }

run_harness() { PATH="$stubs:$PATH" bash "$repo/tests/build-harness.sh" "$@"; }

@test "eval mode runs nix build --dry-run, nothing linked" {
  run run_harness -- '.#x'
  [ "$status" -eq 0 ]
  grep -q "^nix build --no-link --dry-run .#x" "$calls"
  [[ "$output" == *"mode=eval"* ]]
}

@test "--build links an out-path and reports what landed in it" {
  run run_harness --build --link "$out" -- '.#x'
  [ "$status" -eq 0 ]
  grep -q "^nix build --out-link $out .#x" "$calls"
  [[ "$output" == *"mode=build"* ]]
  [[ "$output" == *"out=$out"* ]]
  [[ "$output" == *"installed=1.0 MiB"* ]]
}

@test "NIX_CONFIG carries the flakes flag; --stats turns on NIX_SHOW_STATS" {
  run run_harness -- '.#x'
  grep -q "NIX_CONFIG=experimental-features = nix-command flakes" "$calls"
  grep -q "NIX_SHOW_STATS=unset" "$calls"
  run run_harness --stats -- '.#x'
  grep -q "NIX_SHOW_STATS=1" "$calls"
}

@test "extra arguments after the attribute reach nix verbatim" {
  run run_harness --build --link "$out" -- '.#x' --option gc-auto 1000
  grep -q -- "--option gc-auto 1000" "$calls"
}

@test "a missing '--' or a missing attribute is refused without running anything" {
  run run_harness --cap 1200 '.#x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
  run run_harness --
  [ "$status" -ne 0 ]
  [ ! -s "$calls" ]
}

@test "--cap reaches the scope line, and the client's exit code is the harness's" {
  NIX_EXIT=3 run run_harness --cap 1200 -- '.#x'
  [ "$status" -eq 3 ]
  [[ "$output" == *"cap=1200MB"* ]]
  [[ "$output" == *"exit=3"* ]]
}

@test "peak and swap come from the scope, not from the client" {
  run run_harness --cap 600 -- '.#x'
  [[ "$output" == *"peak="* ]]
  [[ "$output" == *"swap="* ]]
}
