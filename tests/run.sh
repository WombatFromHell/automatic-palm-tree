#!/usr/bin/env bash
# Eval-only test gate. Green suites must print "OK <suite>"; red guards in
# tests/red/ must throw, with the message named in their first line
# (`# expect: <substring>`). Nothing here runs `nix build`.
set -u
cd "$(dirname "$0")/.."

# nix writes fetcher locks under $XDG_CACHE_HOME, which is read-only in some
# sandboxes; fall back to a scratch cache dir rather than failing every suite.
cache="${XDG_CACHE_HOME:-$HOME/.cache}"
if ! mkdir -p "$cache" 2>/dev/null || [ ! -w "$cache" ]; then
  cache="${TMPDIR:-/tmp}/nix-eval-cache"
  mkdir -p "$cache"
fi
export XDG_CACHE_HOME="$cache"

fail=0

for suite in tests/*.nix; do
  case "$suite" in tests/support.nix) continue ;; esac
  if out=$(nix eval --impure --file "$suite" 2>&1); then
    echo "ok   $suite  $out"
  else
    echo "FAIL $suite"
    echo "$out" | tail -20
    fail=1
  fi
done

# Byte-parity between the two template expanders, which live in different runtimes:
# lib/updater.sh render_url (bash, at fetch time) and lib/pin-meta.nix releaseAsset
# (Nix, at eval time). Both must produce the same URL for every pin and system, or a
# pin update drifts silently and only shows up as a build-time hash mismatch.
par=0
for script in features/*/update.sh; do
  meta="$PWD/$(dirname "$script")/metadata.json"
  [ -e "$meta" ] || continue
  ver=$(jq -r .version "$meta")
  for sys in $(jq -r '.hashes | keys[]' "$meta"); do
    want=$(nix eval --impure --raw --expr \
      "let lib = (builtins.getFlake \"nixpkgs\").lib; m = import ./lib/pin-meta.nix {inherit lib;};
       in (m.releaseAsset (builtins.fromJSON (builtins.readFile (builtins.toPath \"$meta\"))) \"$sys\").url")
    got=$(. "$script"; render_url "$sys" "$ver")
    if [ "$want" != "$got" ]; then
      echo "FAIL parity $meta $sys"
      echo "  nix:  $want"
      echo "  bash: $got"
      par=1
    fi
  done
done
if [ "$par" = 0 ]; then
  echo "ok   expander parity"
else
  fail=1
fi

for guard in tests/red/*.nix; do
  want=$(head -n 1 "$guard" | sed 's/^# expect: //')
  if out=$(nix eval --impure --file "$guard" 2>&1); then
    echo "FAIL $guard  expected a throw mentioning \"$want\""
    fail=1
  elif case "$out" in *"$want"*) true ;; *) false ;; esac; then
    echo "ok   $guard"
  else
    echo "FAIL $guard  expected \"$want\""
    echo "$out" | tail -8
    fail=1
  fi
done

exit "$fail"
