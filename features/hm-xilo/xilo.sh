#!/usr/bin/env bash
# xilo-wrapped — the real xilo CLI plus its credentials.
#
# Use it for anything that needs a token (`xilo-wrapped push ...`, `xilo-wrapped status`);
# plain `xilo` is the unmodified upstream CLI.
#
# XILO_URL, XILO_CACHE and XILO_TOKEN are filled from credsctl records ($CREDENTIALS_DIRECTORY,
# default ~/.local/share/credentials) before the CLI runs. Per-key records win, and a key stored in
# both backends is asked for as <key>.sops.json: naming the backend is explicit, and systemd-creds
# costs ~1.2s per decrypt (the Varlink/polkit hop) while sops costs ~23ms. A sops record may be
# either shape — .sops.json is asked for ahead of .sops.yaml, and both cost the same, because the
# plaintext credsctl reads is json either way. What no per-key record covers is filled from the
# bundle record XILO.sops.json or XILO.sops.yaml — any case, since its fields are exactly these
# variable names — in one decrypt for the whole set. A variable you exported yourself wins, so the
# bundle is
# skipped whenever you exported one of them (its fields would replace your value); with no credsctl
# or no record your environment is passed through untouched and xilo's own saved profile
# authenticates. Secrets never reach stdout or your shell: credsctl execs the CLI with them in its
# environment only.
#
# Exit codes are xilo's — credsctl's 2 ("no record") is handled here, not forwarded.
set -uo pipefail

cred_dir="${CREDENTIALS_DIRECTORY:-$HOME/.local/share/credentials}"
# XILO_PROGRAM stands in for the store path in tests; the packaged wrapper has it baked in.
real="${XILO_PROGRAM:-__XILO_PROGRAM__}"

names=()
exported=0
missing=0
for key in XILO_URL XILO_CACHE XILO_TOKEN; do
  if [[ -n ${!key:-} ]]; then
    exported=1
  elif [[ -e "$cred_dir/$key.sops.json" ]]; then
    names+=("$key.sops.json")
  elif [[ -e "$cred_dir/$key.sops.yaml" ]]; then
    names+=("$key.sops.yaml")
  elif [[ -e "$cred_dir/$key.cred" ]]; then
    names+=("$key")
  else
    missing=1
  fi
done

# Asked for first, so a per-key record overrides the bundle's field for the same variable. It is
# asked for by the name actually on disk: the bundle's own case is free, because its fields are the
# variables, while a bare XILO would resolve nothing on a lowercase file and would be refused by
# credsctl when both shapes exist. json before yaml — same cost, json read first. Per-key records
# stay exact-case: there the filename *is* the variable, so a lowercase one would fill a variable
# xilo never reads.
bundle_json="" bundle_yaml=""
if [[ $exported == 0 && $missing == 1 ]]; then
  shopt -s nullglob nocaseglob
  for f in "$cred_dir"/XILO.sops.*; do
    case "${f,,}" in
    # The basename, not the path: --env takes a name and credsctl resolves it inside cred_dir.
    *.sops.json) [[ -z $bundle_json ]] && bundle_json="${f##*/}" ;;
    *.sops.yaml) [[ -z $bundle_yaml ]] && bundle_yaml="${f##*/}" ;;
    esac
  done
  shopt -u nullglob nocaseglob
fi
bundle="${bundle_json:-$bundle_yaml}"
[[ -n $bundle ]] && names=("$bundle" "${names[@]}")

if [[ ${#names[@]} -gt 0 ]] && command -v credsctl >/dev/null 2>&1; then
  exec credsctl decrypt --env "${names[@]}" -- "$real" "$@"
fi
exec "$real" "$@"
