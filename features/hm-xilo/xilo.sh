#!/usr/bin/env bash
# xilo-wrapped — the real xilo CLI plus its credentials.
#
# Use it for anything that needs a token (`xilo-wrapped push ...`, `xilo-wrapped status`);
# plain `xilo` is the unmodified upstream CLI.
#
# XILO_URL, XILO_CACHE and XILO_TOKEN are filled from credsctl records before the CLI runs. Which
# records exist is asked of credsctl (`credsctl list`), because credsctl owns the store location
# (CREDS_DIR, CREDENTIALS_DIRECTORY, CREDS_ROOT) — spelling a path here would guess a store credsctl
# never reads; hm-njust's _push delegates the same way. Per-key records win, and a key stored in both
# backends is asked for as <key>.sops.json: naming the backend is explicit, and sops decrypts far
# cheaper than the Varlink/polkit hop systemd-creds pays (the measured cost of each is in credsctl's
# header). A sops record may be either shape — .sops.json is asked for ahead of .sops.yaml, and both
# cost the same, because the plaintext credsctl reads is json either way. What no per-key record covers
# is filled from the bundle record XILO.sops.json or XILO.sops.yaml — any case, since its fields are
# exactly these variable names — in one decrypt for the whole set. A variable you exported yourself
# wins, so the bundle is skipped whenever you exported one of them (its fields would replace your
# value); an unreadable store or no record leaves your environment alone and xilo's own saved profile
# authenticates. Without credsctl on PATH the wrapper says so — hm-xilo ships on a host that lists
# only it, where records on disk would otherwise be ignored. Secrets never reach stdout or your shell:
# credsctl execs the CLI with them in its environment only, and list reports names, never values.
#
# Exit codes are xilo's, except one: a record that exists but cannot be decrypted is credsctl's 3, and
# running xilo on a credential that is not live is worse than failing, so that failure is passed on.
set -uo pipefail

# XILO_PROGRAM stands in for the store path in tests; the packaged wrapper has it baked in.
real="${XILO_PROGRAM:-__XILO_PROGRAM__}"

names=()
exported=0
declare -A record=()
have_credsctl=0
if command -v credsctl >/dev/null 2>&1; then
  have_credsctl=1
  # One process that decrypts nothing: the names credsctl lists are the names it can read, and a store
  # it cannot read (exit 1 or 3) lists nothing — the same as no record.
  # shortcut: a record name containing a space would be read as its first word, since list prints one
  # name per line; credential names here are variable names, which never contain one.
  while read -r name _; do
    [[ -n $name ]] && record["$name"]=1
  done < <(credsctl list 2>/dev/null)
fi

for key in XILO_URL XILO_CACHE XILO_TOKEN; do
  # Counted, not flagged: the notice below needs to know whether anything at all was supplied.
  [[ -n ${!key:-} ]] && {
    exported=$((exported + 1))
    continue
  }
  # json before yaml (same cost, json read first), systemd-creds last. A plain store lists a .cred
  # file under its own name, a systemd store under the bare name systemd-creds mounted; both are
  # asked for bare. Per-key records stay exact-case: there the filename IS the variable, so a
  # lowercase one would fill a variable xilo never reads.
  for suffix in .sops.json .sops.yaml .cred ""; do
    [[ -v record["$key$suffix"] ]] && {
      names+=("$key${suffix/.cred/}")
      break
    }
  done
done

# The bundle is asked for by the name credsctl listed (its fields are the variables, so its case is
# free) and prepended, so a per-key record appended after it overrides the same variable.
bundle_json="" bundle_yaml=""
if [[ $exported == 0 && ${#names[@]} -lt 3 ]]; then
  for name in "${!record[@]}"; do
    case "${name,,}" in
    xilo.sops.json) [[ -z $bundle_json ]] && bundle_json="$name" ;;
    xilo.sops.yaml) [[ -z $bundle_yaml ]] && bundle_yaml="$name" ;;
    esac
  done
fi
bundle="${bundle_json:-$bundle_yaml}"
[[ -n $bundle ]] && names=("$bundle" "${names[@]}")

# Nothing can be asked for and something is still missing: name the fallback, once. A caller who
# exported all three variables has nothing to look for, so this stays silent.
[[ $have_credsctl == 0 && ${#names[@]} -eq 0 && $exported -lt 3 ]] &&
  printf 'xilo-wrapped: no credsctl on PATH — hm-creds ships it; xilo runs on your environment alone\n' >&2

# A decrypt that fails is credsctl's own failure, not a reason to run the CLI on a stale credential.
[[ ${#names[@]} -gt 0 ]] && exec credsctl decrypt --env "${names[@]}" -- "$real" "$@"
exec "$real" "$@"
