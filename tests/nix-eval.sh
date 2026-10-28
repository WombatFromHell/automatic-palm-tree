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
# the unit (must be a systemd unit name: no '/'). Falls back to an unscoped run when there is no
# user systemd instance to scope under.
set -u

cap="${1:?usage: nix-eval.sh <memory-max-MB> -- <command> [args...]}"
shift
[ "${1:-}" = -- ] || {
  echo "nix-eval.sh: expected '--' after the memory cap" >&2
  exit 2
}
shift

# Availability: the user manager must be reachable. `systemctl --user is-system-running`
# exits 1 on a degraded manager (this box), so check the bus socket instead.
if ! [ -S "/run/user/$(id -u)/bus" ]; then
  "$@"
  exit $?
fi

# Output is a file rather than a command substitution: a substitution would wait for the
# backgrounded scope before the poll loop could run.
tmp=$(mktemp "${TMPDIR:-/tmp}/nix-eval-out.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# systemd reports MemoryPeak only while the unit exists, and it is the peak *so far*, so it is
# polled while the eval is alive: a fast suite exits before a slow poll would ever sample it.
# MemoryCurrent/MemoryPeak are bytes.
unit="${TEST_SCOPE_NAME:-nix-eval}.scope"
systemd-run --user --scope -q --expand-environment=no --unit="$unit" \
  -p MemoryHigh=$((cap * 9 / 10))M -p MemoryMax="${cap}M" -p MemorySwapMax=$((cap / 2))M \
  "$@" >"$tmp" 2>&1 &
runner=$!
peak=0
while kill -0 "$runner" 2>/dev/null; do
  for prop in MemoryCurrent MemoryPeak; do
    n=$(systemctl --user show "$unit" -p "$prop" --value 2>/dev/null | head -n 1)
    case "$n" in (*[!0-9]* | '') n=0 ;; esac
    [ "$n" -gt "$peak" ] && peak=$n
  done
  sleep 0.02
done
wait "$runner"
code=$?
if [ "$code" = 137 ]; then
  echo "nix-eval.sh: killed at ${cap}MB (MemoryMax) — raise TEST_MEMORY_MAX_MB or split the eval" >&2
fi
printf '%s\n' "$(cat "$tmp")"
echo "peak=$((peak / 1024 / 1024))MB" >&2
exit "$code"
