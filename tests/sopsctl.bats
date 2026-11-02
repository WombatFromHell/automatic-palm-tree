#!/usr/bin/env bash
# features/hm-creds/sopsctl.sh against PATH stubs, plus one real-binary round trip.
#
# Contract under test: the key comes from $SOPS_KEYS_CMD (sops calls it itself — no key file, no
# terminal); encrypt reads JSON on stdin and writes ciphertext to stdout with the json types
# explicit; a record is a JSON map whose OWN metadata names the recipients, so `set` re-encrypts to
# those; `set` replaces the record and leaves it 0400 (sops --set writes in place, which a 0400
# file forbids); `verify` proves the MAC without printing plaintext. Exit codes: 1 usage, 2 no such
# record, 3 encrypt or decrypt failed.
#
# Stubs record argv so the flags sops actually receives are asserted, not grepped for. The stub
# encrypt stamps a sops recipient block so the metadata path is exercised, and the stub decrypt
# strips it, as real sops does.
bats_require_minimum_version 1.5.0

setup() {
  repo="$PWD"
  script="$repo/features/hm-creds/sopsctl.sh"
  host_path="$PATH"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : >"$calls"
  store="$stubs/store"
  mkdir -p "$store"
  printf 'age1aaa\nage1bbb\n' >"$store/recipient"
  printf 'AGE-SECRET-KEY-1TEST\n' >"$stubs/key"

  cat >"$stubs/sops" <<EOF
#!/usr/bin/env bash
echo "sops \$* | keycmd=\${SOPS_AGE_KEY_CMD:-none}" >> "$calls"
case "\$1" in
  -e)
    [ "\${SOPS_ENCRYPT_EXIT:-0}" = 0 ] || exit "\$SOPS_ENCRYPT_EXIT"
    jq -c '. + {sops: {age: [{recipient: "age1meta"}]}}' ;;
  -d)
    [ "\${SOPS_DECRYPT_EXIT:-0}" = 0 ] || exit "\$SOPS_DECRYPT_EXIT"
    path=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "--extract" ] && path="\$a"
      prev="\$a"
    done
    if [ -n "\$path" ]; then jq -r ".\$path" "\${@: -1}"; else jq -c 'del(.sops)' "\${@: -1}"; fi ;;
  *) exit 9 ;;
esac
EOF
  cat >"$stubs/kwallet-query" <<EOF
#!/usr/bin/env bash
echo "kwallet \$*" >> "$calls"
mode=r
for a in "\$@"; do [ "\$a" = "-w" ] && mode=w; done
if [ "\$mode" = w ]; then cat >"$stubs/wallet"; exit 0; fi
[ -f "$stubs/wallet" ] || { echo "stub: no wallet entry" >&2; exit 1; }
cat "$stubs/wallet"
EOF
  cat >"$stubs/age-keygen" <<EOF
#!/usr/bin/env bash
cat >"\${@: -1}" <<'KEY'
# created: stub
# public key: age1stub
AGE-SECRET-KEY-1TEST
KEY
EOF
  chmod +x "$stubs/sops" "$stubs/kwallet-query" "$stubs/age-keygen"

  export SOPS_RECIPIENTS="$store/recipient"
  export SOPS_KEYS_CMD="kwallet-query -f flakeroot -r creds-identity kdewallet"
  PATH="$stubs:$PATH"
  record="$store/TOKEN.sops.json"
  printf '{"secret":"s3cr3t"}' | ctl encrypt >"$record"
  chmod 400 "$record"
}

teardown() { rm -rf "$stubs"; }

ctl() { bash "$script" "$@"; }

# --- keys -------------------------------------------------------------------

@test "init stores a fresh identity in the wallet and records its public key" {
  : >"$calls"
  run ctl init
  [ "$status" -eq 0 ]
  grep -q '^kwallet -f flakeroot -w creds-identity kdewallet$' "$calls"
  grep -q 'age1stub' "$SOPS_RECIPIENTS"
  [ -f "$stubs/wallet" ]
}

@test "init is idempotent: an existing identity writes nothing" {
  printf 'AGE-SECRET-KEY-1TEST\n' >"$stubs/wallet"
  run ctl init
  [ "$status" -eq 0 ]
  run ! grep -q ' -w ' "$calls"
}

@test "keys prints recipient public keys and never a secret key" {
  run ctl keys
  [ "$status" -eq 0 ]
  [ "$output" = "age1aaa,age1bbb" ]
  run ! grep -q 'AGE-SECRET-KEY' <<<"$output"
}

# --- encrypt / decrypt ------------------------------------------------------

@test "encrypt names the json types explicitly and takes recipients from the recipient file" {
  run ctl encrypt <<'EOF'
{"secret":"x"}
EOF
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type json --age age1aaa,age1bbb /dev/stdin' "$calls"
}

@test "encrypt with no recipient file exits 1 and calls nothing" {
  rm "$SOPS_RECIPIENTS"
  : >"$calls"
  run ctl encrypt <<'EOF'
{"secret":"x"}
EOF
  [ "$status" -eq 1 ]
  run ! grep -q '^sops ' "$calls"
}

@test "decrypt and get ask sops for a key by command, so no key file and no terminal are needed" {
  run ctl get secret "$record"
  [ "$status" -eq 0 ]
  [ "$output" = "s3cr3t" ]
  grep -q '^sops -d --extract \["secret"\] .*keycmd=kwallet-query -f flakeroot -r creds-identity kdewallet$' "$calls"
}

@test "a missing record exits 2 and a failing decrypt exits 3" {
  run ctl get secret "$store/nope.sops.json"
  [ "$status" -eq 2 ]
  SOPS_DECRYPT_EXIT=128 run ctl decrypt "$record"
  [ "$status" -eq 3 ]
}

@test "verify proves integrity without printing the plaintext" {
  run ctl verify "$record"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  SOPS_DECRYPT_EXIT=25 run ctl verify "$record"
  [ "$status" -eq 3 ]
}

# --- set / rekey ------------------------------------------------------------

# sops --set rewrites in place and a 0400 record refuses that, so a field edit has to decrypt,
# edit the JSON, re-encrypt to the recipients already embedded in the record, and replace the file.
@test "set edits one field, re-encrypts to the record's own recipients, and keeps the record 0400" {
  run ctl set secret "new-value" "$record"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$record")" = "400" ]
  run ctl get secret "$record"
  [ "$output" = "new-value" ]
  grep -q '^sops -e --input-type json --output-type json --age age1meta /dev/stdin ' "$calls"
  run ! ls "$store"/TOKEN.sops.json.* >/dev/null 2>&1
}

@test "set refuses a field name that is not usable and a record with no recipients" {
  run ctl set 'bad field' v "$record"
  [ "$status" -eq 1 ]
  printf '{"secret":"x"}' >"$store/RAW.sops.json"
  chmod 400 "$store/RAW.sops.json"
  run ctl set secret v "$store/RAW.sops.json"
  [ "$status" -eq 3 ]
}

@test "rekey re-encrypts records to the recipient file" {
  : >"$calls"
  run ctl rekey "$record"
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type json --age age1aaa,age1bbb /dev/stdin ' "$calls"
  run ctl get secret "$record"
  [ "$output" = "s3cr3t" ]
}

# --- real binary ------------------------------------------------------------

@test "real sops round trip: encrypt, get, set, and a tampered record fails verify" {
  PATH="$host_path" command -v sops >/dev/null 2>&1 || skip "no sops on the host PATH"
  PATH="$host_path"
  store2="$stubs/real"
  mkdir -p "$store2"
  # The generated key must match the recipient, so generate one and use its own public key.
  PATH="$host_path" age-keygen -o "$stubs/realkey" 2>/dev/null || skip "no age-keygen on the host PATH"
  grep '^# public key:' "$stubs/realkey" | awk '{print $NF}' >"$store2/recipient"
  export SOPS_RECIPIENTS="$store2/recipient"
  export SOPS_KEYS_CMD="cat $stubs/realkey"
  cipher=$(jq -n --arg v "$(printf 'line1\nline2')" '{secret:$v}' | ctl encrypt)
  printf '%s' "$cipher" >"$store2/A.sops.json"
  chmod 400 "$store2/A.sops.json"
  run ctl get secret "$store2/A.sops.json"
  [ "$status" -eq 0 ]
  [ "$output" = "line1
line2" ]
  run ctl verify "$store2/A.sops.json"
  [ "$status" -eq 0 ]
  run ctl set secret "second" "$store2/A.sops.json"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$store2/A.sops.json")" = "400" ]
  run ctl get secret "$store2/A.sops.json"
  [ "$output" = "second" ]
  sed -i 's/ENC\[AES256_GCM,data:[A-Za-z0-9+/]\{4\}/ENC[AES256_GCM,data:XXXX/' "$store2/A.sops.json"
  run ctl verify "$store2/A.sops.json"
  [ "$status" -eq 3 ]
}
