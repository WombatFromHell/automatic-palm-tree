#!/usr/bin/env bash
# Assertion floors: the counts every suite must keep contributing, held by tests/suite-ledger.txt.
# Source counts only — no eval, no build — so the guard costs ~0MB and runs in the stub tier.
#
# It exists because a fixture refactor is the change that silently loses an assertion. The gate
# would otherwise print "ok <suite>" for a suite that now proves less. Floors ratchet up only, so
# deleting a check is a deliberate edit to the ledger, visible in the diff.
#
# Ledger line: "<path> <kind> <floor>". Kinds:
#   assert  an assert_* call in a bats suite
#   checks  a ck "…" call in an eval-tier suite (the checks support.nix's suite() reports)
#   attrs   a test* attribute (nix-unit treats only those as tests)
#
# stdout is machine-readable ("<path> <kind> <count>" per floored suite) so tests/run.sh can put
# the counts on its verdict lines. A shortfall, a suite that no longer exists, or a suite carrying
# assertions with no floor all print FAIL and exit 1.
set -u

tests_dir="${TESTS_DIR:-$(dirname "$0")}"
ledger="${LEDGER:-$tests_dir/suite-ledger.txt}"

if [ ! -f "$ledger" ]; then
  echo "FAIL $ledger [no such ledger]"
  exit 1
fi

count() {
  case "$1" in
    assert) grep -c 'assert_' "$2" ;;
    checks) grep -c 'ck "' "$2" ;;
    attrs) grep -cE '^[[:space:]]*test[A-Za-z0-9_]*[[:space:]]*=' "$2" ;;
  esac
}

fail=0
covered=" "

while read -r path kind floor _; do
  case "$path" in '' | '#'*) continue ;; esac
  if [ ! -f "$tests_dir/${path##*/}" ]; then
    echo "FAIL $path [no such suite]"
    fail=1
    continue
  fi
  case "$kind" in
    assert | checks | attrs) ;;
    *)
      echo "FAIL $path [unknown kind $kind]"
      fail=1
      continue
      ;;
  esac
  case "$floor" in
    '' | *[!0-9]*)
      echo "FAIL $path [unreadable floor '$floor']"
      fail=1
      continue
      ;;
  esac
  got=$(count "$kind" "$tests_dir/${path##*/}")
  covered="$covered${path##*/} "
  if [ "$got" -lt "$floor" ]; then
    echo "FAIL $path $kind floor=$floor count=$got"
    fail=1
    continue
  fi
  echo "$path $kind $got"
done <"$ledger"

# A suite that carries assertions but has no floor is the other way to lose coverage: a new file
# joins the tree, prints ok, and nobody ever counts it. helpers.bash is sourced, not a suite, so
# only *.bats files are checked here.
for f in "$tests_dir"/*.bats "$tests_dir"/*.nix; do
  [ -e "$f" ] || continue
  case "$f" in
    *.bats) claim=$(grep -c 'assert_' "$f") ;;
    *)
      claim=$(( $(grep -c 'ck "' "$f") + $(grep -cE '^[[:space:]]*test[A-Za-z0-9_]*[[:space:]]*=' "$f") ))
      ;;
  esac
  [ "$claim" -gt 0 ] || continue
  case "$covered" in *" ${f##*/} "*) ;; *) echo "FAIL tests/${f##*/} [unfloored]"; fail=1 ;; esac
done

exit "$fail"
