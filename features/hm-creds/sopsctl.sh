#!/usr/bin/env bash
# sopsctl — the sops plumbing behind .sops.json records.
#
# A record is a JSON map whose values sops encrypts, and the recipients live in the record's own
# metadata, so a field edit re-encrypts to whoever already holds it. Keys come from $SOPS_KEYS_CMD:
# sops runs that command itself when it needs a key, so nothing is written to disk and no terminal
# is involved. Plaintext only ever goes to stdout.
#
# Decrypting a *.sops.json file needs no type flags; encrypting from stdin does — without
# --input-type/--output-type json sops reads stdin as binary and re-keys the payload under `data`.
# sops stamps `unencrypted_suffix: "_unencrypted"`, so a field named e.g. `host_unencrypted` stays
# readable in the file; that is the only way to keep a field in plain text.
set -uo pipefail

keys_cmd="${SOPS_KEYS_CMD:-kwallet-query -f flakeroot -r creds-identity kdewallet}"
recipients="${SOPS_RECIPIENTS:-$HOME/.local/share/credentials/recipient}"
wallet=(flakeroot creds-identity)

die() {
  echo "sopsctl: $1" >&2
  exit "${2:-1}"
}

usage() {
  printf '%s\n' \
    "usage: sopsctl <command> ..." \
    "" \
    "  init                    generate an age identity, keep the secret in the wallet, add the public key to \$SOPS_RECIPIENTS" \
    "  keys                    the recipient public keys (never a secret key)" \
    "  encrypt                 JSON on stdin -> ciphertext on stdout; the caller names the file and its mode" \
    "  decrypt FILE            plaintext JSON on stdout" \
    "  get FIELD FILE          one field's value" \
    "  set FIELD VALUE FILE    replace one field, re-encrypted to the record's own recipients" \
    "  rekey FILE ...          re-encrypt records to \$SOPS_RECIPIENTS" \
    "  recipients FILE         the recipients embedded in a record" \
    "  verify FILE             decrypt to /dev/null: exit 0 means the MAC is intact, no plaintext printed" \
    "" \
    "  overrides               SOPS_KEYS_CMD (how a key is fetched), SOPS_RECIPIENTS (who can read a record)" \
    "  exit codes              0 ok · 1 bad usage · 2 no such record · 3 encrypt or decrypt failed"
}

run_sops() { SOPS_AGE_KEY_CMD="$keys_cmd" sops "$@"; }

recipient_list() {
  [[ -r $recipients ]] || die "no recipient file: $recipients (one age public key per line)"
  grep -v '^#' "$recipients" | paste -sd, -
}

need_file() { [[ -f $1 ]] || die "no record: $1" 2; }

need_field() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid field name '$1' (letters, digits, _)" 1; }

# Replace a record with a re-encrypted version of whatever stdin hands it. sops --set writes in
# place, which a 0400 record forbids, so every change goes through here and lands as 0400.
rewrite() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")" || die "cannot write a temp record beside $1"
  run_sops -e --input-type json --output-type json --age "$2" /dev/stdin >"$tmp" ||
    { rm -f "$tmp"; die "cannot rewrite $1" 3; }
  mv -- "$tmp" "$1"
  chmod 400 "$1"
}

cmd_encrypt() {
  local recs
  recs="$(recipient_list)" || exit 1
  run_sops -e --input-type json --output-type json --age "$recs" /dev/stdin ||
    die "encrypt failed" 3
}

cmd_decrypt() {
  need_file "$1"
  run_sops -d "$1" || die "cannot decrypt $1" 3
}

cmd_get() {
  [[ $# -eq 2 ]] || die "get needs FIELD FILE" 1
  need_field "$1"
  need_file "$2"
  run_sops -d --extract "[\"$1\"]" "$2" || die "cannot read $1 from $2" 3
}

cmd_set() {
  [[ $# -eq 3 ]] || die "set needs FIELD VALUE FILE" 1
  need_field "$1"
  need_file "$3"
  local plain recs
  plain=$(run_sops -d "$3") || die "cannot decrypt $3" 3
  recs=$(jq -r '.sops.age[].recipient' "$3" | paste -sd, -)
  [[ -n $recs ]] || die "no recipients in $3" 3
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"$plain" | rewrite "$3" "$recs" ||
    die "cannot set $1 in $3" 3
}

# Recipient rotation: sops has no flag that changes recipients without a config file, so
# re-encrypting is the rekey.
cmd_rekey() {
  [[ $# -gt 0 ]] || die "rekey needs at least one record" 1
  local recs file
  recs="$(recipient_list)" || exit 1
  for file in "$@"; do
    need_file "$file"
    run_sops -d "$file" | rewrite "$file" "$recs" || die "cannot rekey $file" 3
  done
}

cmd_recipients() {
  need_file "$1"
  jq -r '.sops.age[].recipient' "$1"
}

cmd_verify() {
  need_file "$1"
  run_sops -d "$1" >/dev/null || die "cannot verify $1 — MAC or key failure" 3
}

cmd_init() {
  # shellcheck disable=SC2086  # SOPS_KEYS_CMD is a command to run, not an argument
  if $keys_cmd >/dev/null 2>&1; then
    printf 'identity already in %s/%s\n' "${wallet[0]}" "${wallet[1]}"
    return
  fi
  local tmp pub
  tmp="$(mktemp)" || die "cannot create a temp key"
  age-keygen -o "$tmp" || { rm -f "$tmp"; die "age-keygen failed" 3; }
  pub="$(grep '^# public key:' "$tmp" | awk '{print $NF}')"
  [[ -n $pub ]] || { rm -f "$tmp"; die "age-keygen printed no public key" 3; }
  kwallet-query -f "${wallet[0]}" -w "${wallet[1]}" kdewallet <"$tmp" ||
    { rm -f "$tmp"; die "cannot store the identity in the wallet" 3; }
  rm -f "$tmp"
  mkdir -p "$(dirname "$recipients")"
  grep -qx "$pub" "$recipients" 2>/dev/null || printf '%s\n' "$pub" >>"$recipients"
  printf 'identity stored in %s/%s\npublic key %s added to %s\n' \
    "${wallet[0]}" "${wallet[1]}" "$pub" "$recipients"
}

case "${1:-}" in
init) cmd_init ;;
keys)
  recipient_list
  ;;
encrypt) cmd_encrypt ;;
decrypt)
  shift
  cmd_decrypt "$@"
  ;;
get)
  shift
  cmd_get "$@"
  ;;
set)
  shift
  cmd_set "$@"
  ;;
rekey)
  shift
  cmd_rekey "$@"
  ;;
recipients)
  shift
  cmd_recipients "$@"
  ;;
verify)
  shift
  cmd_verify "$@"
  ;;
"" | -h | --help | help) usage ;;
*) die "unknown command '$1' — 'sopsctl help' lists the commands" ;;
esac
