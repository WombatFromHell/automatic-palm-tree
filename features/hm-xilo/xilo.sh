#!/usr/bin/env bash
# xilo-wrapped — the real xilo CLI plus its credentials.
#
# Use it for anything that needs a token (`xilo-wrapped push ...`, `xilo-wrapped status`);
# plain `xilo` is the unmodified upstream CLI.
#
# XILO_URL, XILO_CACHE and XILO_TOKEN are filled from credsctl records ($CREDENTIALS_DIRECTORY,
# default ~/.local/share/credentials) before the CLI runs. Per-key records win, and a key stored in
# both backends is asked for as <key>.sops.json: naming the backend is explicit, and sops decrypts far
# cheaper than the Varlink/polkit hop systemd-creds pays (the measured cost of each is in credsctl's
# header). A sops record may be either shape — .sops.json is asked for ahead of .sops.yaml, and both
# cost the same, because the plaintext credsctl reads is json either way. What no per-key record covers
# is filled from the bundle record XILO.sops.json or XILO.sops.yaml — any case, since its fields are
# exactly these variable names — in one decrypt for the whole set. A variable you exported yourself
# wins, so the bundle is skipped whenever you exported one of them (its fields would replace your
# value); with no credsctl or no record your environment is passed through untouched and xilo's own
# saved profile authenticates. Secrets never reach stdout or your shell: credsctl execs the CLI with
# them in its environment only.
#
# Exit codes are xilo's: the wrapper only asks for names it saw on disk.
set -uo pipefail

cred_dir="${CREDENTIALS_DIRECTORY:-$HOME/.local/share/credentials}"
# XILO_PROGRAM stands in for the store path in tests; the packaged wrapper has it baked in.
real="${XILO_PROGRAM:-__XILO_PROGRAM__}"

names=()
exported=0
for key in XILO_URL XILO_CACHE XILO_TOKEN; do
  [[ -n ${!key:-} ]] && {
    exported=1
    continue
  }
  # json before yaml (same cost, json read first), .cred last. Per-key records stay exact-case: there
  # the filename IS the variable, so a lowercase one would fill a variable xilo never reads.
  for ext in .sops.json .sops.yaml .cred; do
    [[ -e "$cred_dir/$key$ext" ]] && {
      names+=("$key${ext/.cred/}")
      break
    }
  done
done

# The bundle is asked for by the name on disk (its fields are the variables, so its case is free)
# and prepended, so a per-key record appended after it overrides the same variable.
bundle_json="" bundle_yaml=""
if [[ $exported == 0 && ${#names[@]} -lt 3 ]]; then
  shopt -s nullglob nocaseglob
  for f in "$cred_dir"/XILO.sops.*; do
    case "${f,,}" in
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
