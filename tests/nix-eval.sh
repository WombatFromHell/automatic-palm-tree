#!/usr/bin/env bash
# Run one command inside a transient systemd scope with a memory cap, so a suite that
# balloons is killed here instead of swapping the machine.
#
# systemd.resource-control(5): MemoryHigh= throttles and reclaims, MemoryMax= is the hard cap
# and OOM-kills inside the unit. Swap is capped rather than forbidden: with MemorySwapMax=0 an
# allocation that cannot be met from free RAM stalls instead of being killed (this box sits near
# 3GB free with 4GB already swapped, and the gate hung). Half the cap keeps the eval bounded so it
# cannot quietly eat the whole swap device.
# `--scope` runs the command as a child of systemd-run and inherits its stdio, so output needs
# no --pipe (this systemd rejects --pipe with --scope anyway). -q drops the unit notice, and
# --expand-environment=no stops systemd-run blanking the `${...}` interpolations inside a Nix
# expression passed as an argument.
#
# Usage: tests/nix-eval.sh <memory-max-MB> -- <command> [args...]
# Prints `peak=<MB>` on stderr: the highest the scope ever reached. Set TEST_SCOPE_NAME to name
# the unit (must be a systemd unit name: no '/'). Falls back to an unscoped run, reporting
# `peak=n/a`, when no scope can be started.
set -u

cap="${1:?usage: nix-eval.sh <memory-max-MB> -- <command> [args...]}"
shift
[ "${1:-}" = -- ] || {
  echo "nix-eval.sh: expected '--' after the memory cap" >&2
  exit 2
}
shift

# Availability: try to start a scope. The bus socket exists on this box while the manager is
# unreachable, so stat-ing it reports "scopable" and every suite then FAILs on a systemd-run
# error. A failed probe is the fact, so it runs unscoped and prints peak=n/a — the same line
# tests/run.sh already turns into peak=n/a when no peak comes back.
if ! systemd-run --user --scope -q --unit="nix-eval-probe-$$.scope" true >/dev/null 2>&1; then
  "$@"
  code=$?
  # The command's own output may end without a newline (`nix eval --raw` does), which would run
  # the peak line into the last output line and corrupt whatever parses it.
  printf '\npeak=n/a\n' >&2
  exit "$code"
fi

# Output is a file rather than a command substitution: a substitution would wait for the
# backgrounded scope before the poll loop could run.
tmp=$(mktemp "${TMPDIR:-/tmp}/nix-eval-out.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# systemd reports MemoryPeak only while the unit exists, and it is the peak *so far*, so it is
# polled while the eval is alive: a fast suite exits before a slow poll would ever sample it.
# MemoryCurrent/MemoryPeak are bytes. The pid is appended because a scope killed by OOM stays
# 'failed' in systemd's unit table, and a second systemd-run with the same --unit then refuses
# with "already loaded" instead of running.
unit="${TEST_SCOPE_NAME:-nix-eval}-$$.scope"
systemd-run --user --scope -q --expand-environment=no --unit="$unit" \
  -p MemoryHigh=$((cap * 9 / 10))M -p MemoryMax="${cap}M" -p MemorySwapMax=$((cap / 2))M \
  "$@" >"$tmp" 2>&1 &
runner=$!
# MemoryPeak is anonymous RAM; MemorySwapPeak is what spilled to disk, which is the part that
# stalls the machine rather than killing it. Older systemd reports nothing for it, so it reads 0.
peak=0
swap=0
while kill -0 "$runner" 2>/dev/null; do
  for prop in MemoryCurrent MemoryPeak; do
    n=$(systemctl --user show "$unit" -p "$prop" --value 2>/dev/null | head -n 1)
    case "$n" in *[!0-9]* | '') n=0 ;; esac
    [ "$n" -gt "$peak" ] && peak=$n
  done
  n=$(systemctl --user show "$unit" -p MemorySwapPeak --value 2>/dev/null | head -n 1)
  case "$n" in *[!0-9]* | '') n=0 ;; esac
  [ "$n" -gt "$swap" ] && swap=$n
  sleep 0.02
done
wait "$runner"
code=$?
if [ "$code" = 137 ]; then
  echo "nix-eval.sh: killed at ${cap}MB (MemoryMax) — raise TEST_MEMORY_MAX_MB or split the eval" >&2
fi
printf '%s\n' "$(cat "$tmp")"
echo "peak=$((peak / 1024 / 1024))MB swap=$((swap / 1024 / 1024))MB" >&2
exit "$code"
