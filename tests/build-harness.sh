#!/usr/bin/env bash
# Build-time telemetry for one attribute: how much RAM it needs and how long it takes, under a
# memory cap. This is what `nix.just` runs, so a measurement here is a measurement of `njust`.
#
# The scope itself is tests/nix-eval.sh's job — cap, MemoryHigh/MemoryMax/MemorySwapMax, the
# peak/swap read-out and the fallback when there is no user systemd. This file only adds wall time
# and, for a real build, what landed in the out-link.
#
# Usage: tests/build-harness.sh [--cap MB] [--build] [--stats] [--link PATH] -- <attr>
#   default   eval only: `nix build --dry-run --no-link`, what `njust eval <attr>` runs.
#   --build   realises instead: `nix build --out-link`, what `njust build <attr>` runs.
#   --stats   NIX_SHOW_STATS=1. It under-reports the peak, so the scope's peak stays authoritative.
#   extra     anything after the attribute is forwarded to `nix build` verbatim.
#
# Telemetry for a rebuild (`nixos-rebuild`, `home-manager switch`) belongs to bootstrap.sh, which
# scopes those itself; tests/nix-eval.sh wraps any other command directly.
#
# One telemetry line on stdout, then the client's own output. Exit code is the client's.
# Overrides: BUILD_HARNESS_MEM (cap, default 3072), BUILD_HARNESS_LINK.
set -u
cd "$(dirname "$0")/.."

# Flakes are not globally enabled on upstream Nix, so the harness carries them itself.
export NIX_CONFIG="experimental-features = nix-command flakes"

cap="${BUILD_HARNESS_MEM:-3072}"
link="${BUILD_HARNESS_LINK:-/tmp/build-harness-result}"
build=0
stats=0

while [ "${1:-}" != "--" ]; do
  case "${1:-}" in
  --cap)
    shift
    cap="${1:?--cap needs a megabyte value}"
    shift
    ;;
  --link)
    shift
    link="${1:?--link needs a path}"
    shift
    ;;
  --build)
    build=1
    shift
    ;;
  --stats)
    stats=1
    shift
    ;;
  *)
    echo "usage: build-harness.sh [--cap MB] [--build] [--stats] [--link PATH] -- <attr>" >&2
    exit 2
    ;;
  esac
done
shift

attr="${1:?build-harness.sh: needs a flake attribute after '--'}"
args=("${@:2}")

if [ "$build" = 1 ]; then
  cmd=(nix build --out-link "$link" "$attr")
else
  cmd=(nix build --no-link --dry-run "$attr")
fi
cmd+=("${args[@]}")

# `${stats:+X}` substitutes even when stats is 0, so the flag is an array, not an expansion.
run=(env "${cmd[@]}")
[ "$stats" = 1 ] && run=(env NIX_SHOW_STATS=1 "${cmd[@]}")

# Wall time is the whole scoped run, so a killed run reports the time it took to die.
start=$(date +%s)
out=$(TEST_SCOPE_NAME=build-harness tests/nix-eval.sh "$cap" -- "${run[@]}" 2>&1)
code=$?
wall=$(( $(date +%s) - start ))

# tests/nix-eval.sh's peak line is its own telemetry, not the client's output.
scope=$(printf '%s\n' "$out" | grep '^peak=' | tail -n 1)
body=$(printf '%s\n' "$out" | grep -v '^peak=')
scope="${scope:-peak=n/a}"

printf 'mode=%s attr=%s cap=%sMB %s wall=%ss exit=%s\n' \
  "$([ "$build" = 1 ] && echo build || echo eval)" "$attr" "$cap" "$scope" "$wall" "$code"

# Real build: what landed in $out. Candidates match nix.just's _activate, since HM puts the
# closure at <link>/activate and a system closure at <link>/toplevel.
if [ "$build" = 1 ]; then
  closure=$(realpath -e "$link/result" "$link/toplevel" "$link" 2>/dev/null | head -n 1)
  [ -n "$closure" ] &&
    printf 'out=%s installed=%s\n' "$closure" "$(nix path-info -Ssh "$closure" 2>/dev/null | awk '{print $(NF - 1), $NF}')"
fi

printf '%s\n' "$body"
exit "$code"
