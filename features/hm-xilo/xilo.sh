#!/usr/bin/env bash
# xilo-wrapped — the real xilo CLI plus its credentials.
#
# Use it for anything that needs a token (`xilo-wrapped push ...`, `xilo-wrapped status`);
# plain `xilo` is the unmodified upstream CLI.
#
# XILO_URL, XILO_CACHE and XILO_TOKEN are filled from credsctl records ($CREDENTIALS_DIRECTORY,
# default ~/.local/share/credentials) before the CLI runs. A variable you exported yourself wins,
# so a one-off token still works; with no credsctl or no record your environment is passed through
# untouched and xilo's own saved profile authenticates. Secrets never reach stdout or your shell:
# credsctl execs the CLI with them in its environment only.
#
# Exit codes are xilo's — credsctl's 2 ("no record") is handled here, not forwarded.
set -uo pipefail

cred_dir="${CREDENTIALS_DIRECTORY:-$HOME/.local/share/credentials}"
# XILO_PROGRAM stands in for the store path in tests; the packaged wrapper has it baked in.
real="${XILO_PROGRAM:-__XILO_PROGRAM__}"

names=()
for key in XILO_URL XILO_CACHE XILO_TOKEN; do
  if [[ -z ${!key:-} ]] && { [[ -e "$cred_dir/$key.cred" || -e "$cred_dir/$key.sops.json" ]]; }; then
    names+=("$key")
  fi
done

if [[ ${#names[@]} -gt 0 ]] && command -v credsctl >/dev/null 2>&1; then
  exec credsctl decrypt --env "${names[@]}" -- "$real" "$@"
fi
exec "$real" "$@"
