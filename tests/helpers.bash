#!/usr/bin/env bash
# Shared harness for the PATH-stub suites in tests/. Load with `load helpers` at the top of a
# .bats file: the scratch dir every suite retyped (stubs, an empty call log, the host PATH the
# real-binary tests fall back to) and teardown. `bats_require_minimum_version` lives here, which is
# what makes `run !` legal in bootstrap.bats and njust.bats without BW02.
# Sourced, not run, so it is never globbed as a suite: the extension is .bash.
bats_require_minimum_version 1.5.0

# Suites that need no fixture beyond this use setup/teardown as-is; the rest override setup and
# call harness_stub_dir first, since bats takes the last definition it saw.
setup() { harness_stub_dir; }
teardown() { harness_teardown; }

harness_stub_dir() {
  repo="$PWD"
  host_path="$PATH"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : >"$calls"
}

harness_teardown() { rm -rf "$stubs"; }

# Assertions on the stub call log (argv as the stub recorded it) and on bats' $output. The log
# ones stay grep — the patterns there are anchored regexes matched against one line per
# invocation — and assert_no_call counts rather than negating grep, so a missing log file fails
# instead of passing on grep's exit 2.
assert_call()     { grep -q -- "$1" "$calls"; }
assert_no_call()  { [ "$(grep -c -- "$1" "$calls")" = 0 ]; }
assert_calls()    { [ "$(grep -c -- "$1" "$calls")" = "$2" ]; }

# $output is one string bats already holds, so absence/presence is a [[ ]] match, not a grep pipe.
assert_out()       { [[ $output == *"$1"* ]]; }
assert_no_out()    { [[ $output != *"$1"* ]]; }
assert_out_count() { [ "$(grep -c -- "$1" <<<"$output")" = "$2" ]; }

# stub <name> — write an executable stub from stdin. A quoted heredoc keeps the body unevaluated.
stub() {
  cat >"$stubs/$1"
  chmod +x "$stubs/$1"
}
