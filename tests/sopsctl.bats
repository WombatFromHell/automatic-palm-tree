#!/usr/bin/env bash
# features/hm-creds/sopsctl.sh against PATH stubs, plus one real-binary round trip.
#
# Contract under test: init keeps the secret half in an age identity file ($SOPS_AGE_FILE, sops'
# own default lookup) and the public half in the recipient file plus a .sops.yaml of creation rules
# beside the records; the key can also come from $SOPS_KEYS_CMD (sops calls it itself — no key file,
# no terminal), which stays the route for anyone who keeps a key in a wallet. Encrypt reads JSON on
# stdin and writes ciphertext to stdout with the json types explicit; a record is a JSON map whose OWN metadata names the recipients, so `set` re-encrypts to
# those; `set` replaces the record and leaves it 0400 (sops --set writes in place, which a 0400
# record forbids); `verify` proves the MAC without printing plaintext. Exit codes: 1 usage, 2 no such
# record, 3 encrypt or decrypt failed.
#
# Stubs record argv so the flags sops actually receives are asserted, not grepped for. The stub
# encrypt stamps a sops recipient block so the metadata path is exercised, and the stub decrypt
# strips it, as real sops does.
#
# bats runs each @test body as one subshell that it runs to completion, so an `export` inside a test
# reaches every command of that test; shellcheck reads the body's commands as separate subshells and
# warns that the change may be lost, which is not true here.
# shellcheck disable=SC2030,SC2031
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

  # ksshaskpass exists in the suite only as a trap: nothing in sopsctl may run it, and the stub
  # outranks whatever the host has on PATH, so any askpass call shows up in the call log.
  cat >"$stubs/ksshaskpass" <<EOF
#!/usr/bin/env bash
echo "ksshaskpass \$*" >> "$calls"
printf 'from-the-trap\n'
EOF
  chmod +x "$stubs/ksshaskpass"

  cat >"$stubs/sops" <<EOF
#!/usr/bin/env bash
echo "sops \$* | keycmd=\${SOPS_AGE_KEY_CMD:-none} | agefile=\${SOPS_AGE_KEY_FILE:-none}" >> "$calls"
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
echo "age-keygen \$*" >> "$calls"
cat >"\${@: -1}" <<'KEY'
# created: stub
# public key: age1stub
AGE-SECRET-KEY-1TEST
KEY
EOF
  cat >"$stubs/ssh-to-age" <<EOF
#!/usr/bin/env bash
echo "ssh-to-age \$*" >> "$calls"
[ -n "\${SSH_TO_AGE_PASSPHRASE:-}" ] && echo "ssh-to-age passphrase-env=set" >> "$calls"
printf 'age1stubderived\n'
EOF
  chmod +x "$stubs/sops" "$stubs/kwallet-query" "$stubs/age-keygen" "$stubs/ssh-to-age"

  # Real keypairs for the passphrase probe: the check reads an OpenSSH header, so the fixture has
  # to be a real key. ssh-keygen is on a Linux host already; a host without it skips those tests.
  ssh-keygen -q -t ed25519 -N 'protectpass' -f "$stubs/ssh_protected" 2>/dev/null || true
  ssh-keygen -q -t ed25519 -N '' -f "$stubs/ssh_unlocked" 2>/dev/null || true

  # init writes the identity here instead of into a wallet, and the rules file beside the
  # records; both are overrides (SOPS_AGE_FILE, SOPS_RULES) so the suite stays inside the fixture.
  export SOPS_AGE_FILE="$stubs/keys.txt"
  rulefile="$store/.sops.yaml" # init puts the rules beside the records
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

# init keeps the secret half in an age identity FILE (sops reads it itself: no wallet, no
# terminal, no key command), the public half in the recipient file and in the rules file that
# `sops -e` uses for new records, and says so.
@test "init writes a 0600 age identity to $SOPS_AGE_FILE and never touches the wallet" {
  : >"$calls"
  run ctl init
  [ "$status" -eq 0 ]
  [ -f "$SOPS_AGE_FILE" ]
  [ "$(stat -c '%a' "$SOPS_AGE_FILE")" = "600" ]
  grep -q 'AGE-SECRET-KEY' "$SOPS_AGE_FILE"
  grep -q '^age-keygen -o ' "$calls"
  run ! grep -q ' -w ' "$calls"
  [ ! -f "$stubs/wallet" ]
}

@test "init seeds a creation_rules file so $(sops -e) gets the key with no flag" {
  run ctl init
  [ "$status" -eq 0 ]
  grep -q 'age1stub' "$SOPS_RECIPIENTS"
  grep -q 'creation_rules:' "$rulefile"
  grep -q 'sops\\.json' "$rulefile"
  grep -q 'age: age1stub' "$rulefile"
}

@test "init tells where each half of the key lives and what to run next" {
  run ctl init
  [ "$status" -eq 0 ]
  grep -q "$SOPS_AGE_FILE" <<<"$output"
  grep -q "$rulefile" <<<"$output"
  grep -q 'age1stub' <<<"$output"
  grep -q 'cd ' <<<"$output"
}

@test "init rerun changes nothing: no second identity, no duplicated recipient" {
  run ctl init
  : >"$calls"
  run ctl init
  [ "$status" -eq 0 ]
  run ! grep -q 'age-keygen' "$calls"
  [ "$(grep -c 'age1stub' "$SOPS_RECIPIENTS")" -eq 1 ]
  [ -f "$stubs/wallet" ] || true
}

@test "keys prints recipient public keys and never a secret key" {
  run ctl keys
  [ "$status" -eq 0 ]
  [ "$output" = "age1aaa,age1bbb" ]
  run ! grep -q 'AGE-SECRET-KEY' <<<"$output"
}

# --- encrypt / decrypt ------------------------------------------------------

@test "an identity file means sops reads it itself: no key command runs and nothing prompts" {
  run ctl init
  : >"$calls"
  run ctl get secret "$record"
  [ "$status" -eq 0 ]
  [ "$output" = "s3cr3t" ]
  grep -q 'agefile=.*keys.txt' "$calls"
  grep -q 'keycmd=none' "$calls"
  run ! grep -q '^kwallet ' "$calls"
}

@test "encrypt names the json types explicitly and takes recipients from the recipient file" {
  run ctl encrypt <<'EOF'
{"secret":"x"}
EOF
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type json --age age1aaa,age1bbb --config /dev/null /dev/stdin' "$calls"
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
  grep -q '^sops -d --extract \["secret"\] .*keycmd=kwallet-query -f flakeroot -r creds-identity kdewallet' "$calls"
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
  grep -q '^sops -e --input-type json --output-type json --age age1meta --config /dev/null /dev/stdin ' "$calls"
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
  grep -q '^sops -e --input-type json --output-type json --age age1aaa,age1bbb --config /dev/null /dev/stdin ' "$calls"
  run ctl get secret "$record"
  [ "$output" = "s3cr3t" ]
}

# --- tilde expansion -------------------------------------------------------

# A quoted ~ (or one from a variable) reaches the script literal, which is how a fish user types a
# path most days, so the path arguments have to be expanded before any command opens them. A
# secret VALUE may legitimately begin with ~, so `set` must keep it byte-for-byte.
# The quoted ~ in this block is deliberate: the test is about a path that arrives unexpanded.
# shellcheck disable=SC2088
@test "a quoted ~ path reaches the commands as a real path and a ~ value stays literal" {
  run ctl protected '~/nope_ed25519'
  [ "$status" -eq 2 ]
  grep -q "no identity: $HOME/nope_ed25519" <<<"$output"
  run ctl decrypt '~/nope.sops.json'
  [ "$status" -eq 2 ]
  grep -q "no record: $HOME/nope.sops.json" <<<"$output"
  run ctl set secret '~/home' "$record"
  [ "$status" -eq 0 ]
  run ctl get secret "$record"
  [ "$output" = "~/home" ]
}

# --- ssh-to-age derivation and the passphrase probe ------------------------

# The ssh keypair is the origin (protected, left alone); the age pair is the disposable artifact,
# so deciding between a passphrase and no prompt has to read the key's own header.
@test "protected names the state of an OpenSSH identity and exits 0 only when a passphrase is needed" {
  [ -f "$stubs/ssh_protected" ] || skip "no ssh-keygen on this host"
  run ctl protected "$stubs/ssh_protected"
  [ "$status" -eq 0 ]
  grep -q 'passphrase-protected' <<<"$output"
  run ctl protected "$stubs/ssh_unlocked"
  [ "$status" -eq 1 ]
  grep -q 'unlocked' <<<"$output"
}

@test "protected refuses a file that is not there and an argument count it cannot use" {
  run ctl protected "$stubs/nope"
  [ "$status" -eq 2 ]
  run ctl protected a b
  [ "$status" -eq 1 ]
}

@test "init --from-ssh takes the age keypair from ssh-to-age, not from age-keygen" {
  run ctl init --from-ssh "$stubs/ssh_unlocked"
  [ "$status" -eq 0 ]
  grep -q '^ssh-to-age -i .*ssh_unlocked\.pub' "$calls"
  grep -q '^ssh-to-age -private-key -i .*ssh_unlocked$' "$calls"
  run ! grep -q 'age-keygen -o ' "$calls"
  grep -q '^# public key: age1stubderived' "$SOPS_AGE_FILE"
  grep -q 'age1stubderived' "$SOPS_RECIPIENTS"
}

@test "init --from-ssh hands the passphrase to ssh-to-age in its environment, never in argv" {
  [ -f "$stubs/ssh_protected" ] || skip "no ssh-keygen on this host"
  run ctl init --from-ssh "$stubs/ssh_protected" <<<"protectpass"
  [ "$status" -eq 0 ]
  grep -q '^ssh-to-age -private-key -i .*ssh_protected$' "$calls"
  grep -q 'ssh-to-age passphrase-env=set' "$calls"
  grep -q 'passphrase for' <<<"$output"
  run ! grep -q 'protectpass' "$calls"
  run ! grep -q 'ksshaskpass' "$calls"
  grep -q '^# created: ssh-to-age from ' "$SOPS_AGE_FILE"
}

@test "init --from-ssh asks at its own prompt even with a display up and runs no askpass helper" {
  [ -f "$stubs/ssh_protected" ] || skip "no ssh-keygen on this host"
  export DISPLAY=:0
  run ctl init --from-ssh "$stubs/ssh_protected" <<<"protectpass"
  [ "$status" -eq 0 ]
  grep -q '^ssh-to-age -private-key -i .*ssh_protected$' "$calls"
  grep -q 'ssh-to-age passphrase-env=set' "$calls"
  grep -q 'passphrase for' <<<"$output"
  run ! grep -q 'ksshaskpass' "$calls"
  grep -q '^# created: ssh-to-age from ' "$SOPS_AGE_FILE"
}

@test "init --from-ssh with no passphrase to read exits 3, names the env route, and writes nothing" {
  [ -f "$stubs/ssh_protected" ] || skip "no ssh-keygen on this host"
  run ctl init --from-ssh "$stubs/ssh_protected" </dev/null
  [ "$status" -eq 3 ]
  grep -q 'SSH_TO_AGE_PASSPHRASE' <<<"$output"
  run ! grep -q 'ssh-to-age' "$calls"
  run ! grep -q 'ssh-to-age from' "$SOPS_AGE_FILE"
}

@test "init --from-ssh takes a passphrase the caller already exported and never prompts" {
  [ -f "$stubs/ssh_protected" ] || skip "no ssh-keygen on this host"
  export SSH_TO_AGE_PASSPHRASE='protectpass'
  run ctl init --from-ssh "$stubs/ssh_protected" </dev/null
  unset SSH_TO_AGE_PASSPHRASE
  [ "$status" -eq 0 ]
  grep -q '^ssh-to-age -private-key -i .*ssh_protected$' "$calls"
  grep -q 'ssh-to-age passphrase-env=set' "$calls"
  run ! grep -q 'passphrase for' <<<"$output"
  run ! grep -q 'protectpass' "$calls"
  run ! grep -q 'ksshaskpass' "$calls"
  grep -q '^# created: ssh-to-age from ' "$SOPS_AGE_FILE"
}

@test "init --from-ssh rerun changes nothing: no prompt, no second derivation, no duplicate recipient" {
  run ctl init --from-ssh "$stubs/ssh_unlocked"
  : >"$calls"
  run ctl init --from-ssh "$stubs/ssh_unlocked"
  [ "$status" -eq 0 ]
  again="$output"
  run ! grep -q 'ssh-to-age' "$calls"
  [ "$(grep -c 'age1stubderived' "$SOPS_RECIPIENTS")" -eq 1 ]
  grep -q 'already derived' <<<"$again"
}

@test "init --from-ssh refuses a keypair missing one half" {
  run ctl init --from-ssh "$stubs/ssh_unlocked-nothere"
  [ "$status" -eq 2 ]
  run ! grep -q 'ssh-to-age' "$calls"
}

@test "init --from-ssh says the origin key is untouched and the age half is regenerable" {
  run ctl init --from-ssh "$stubs/ssh_unlocked"
  [ "$status" -eq 0 ]
  grep -q 'never copied, unlocked or rewritten' <<<"$output"
  grep -q 'sopsctl init --from-ssh' <<<"$output"
}

# --- usage text --------------------------------------------------------------

@test "help prints every command, names which ssh half --from-ssh takes, and runs nothing" {
  : >"$calls"
  run ctl --help
  [ "$status" -eq 0 ]
  grep -q 'recipients embedded in a record' <<<"$output"
  grep -q '^  protected KEY' <<<"$output"
  grep -q 'PRIVATE key without .pub' <<<"$output"
  run ! grep -q 'command not found' <<<"$output"
  run ! grep -q . "$calls"
}

# --- real binary ------------------------------------------------------------

@test "init --from-ssh refuses to replace an identity that came from a different keypair" {
  run ctl init --from-ssh "$stubs/ssh_unlocked"
  : >"$calls"
  run ctl init --from-ssh "$stubs/ssh_protected"
  [ "$status" -ne 0 ]
  grep -q 'identity holds a different keypair' <<<"$output"
  grep -q 'age1stubderived' "$SOPS_AGE_FILE"
  run ! grep -q 'ssh-to-age' "$calls"
}

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
  # The rules file init writes is what a hand-made record uses: encrypt with no --age, decrypt
  # with no key command, both through the identity file alone.
  store3="$stubs/rules"
  mkdir -p "$store3"
  export SOPS_RECIPIENTS="$store3/recipient"
  export SOPS_AGE_FILE="$store3/keys.txt"
  run ctl init
  [ "$status" -eq 0 ]
  printf '{"A":"1"}' >"$store3/a.sops.json"
  (cd "$store3" && sops -e a.sops.json) 2>/dev/null >"$store3/enc.sops.json"
  run ctl get A "$store3/enc.sops.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  sed -i 's/ENC\[AES256_GCM,data:[A-Za-z0-9+/]\{4\}/ENC[AES256_GCM,data:XXXX/' "$store2/A.sops.json"
  run ctl verify "$store2/A.sops.json"
  [ "$status" -eq 3 ]
}

# --- the ssh-to-age passphrase route, against the real binary -------------------------------
#
# The stub suite above proves argv; here the contract is ssh-to-age's own passphrase input, which
# is an environment variable in the release nixpkgs ships. That is the fact most likely to move with
# a new ssh-to-age, so it is pinned against the binary, not a stub (REVIEW.md names this re-check).
@test "a protected ssh origin derives a working identity through SSH_TO_AGE_PASSPHRASE" {
  store4="$stubs/sshstore"
  mkdir -p "$store4"
  export SOPS_AGE_FILE="$store4/keys.txt" SOPS_RECIPIENTS="$store4/recipient"
  export SOPS_RULES="$store4/.sops.yaml"
  PATH="$host_path" ssh-to-age -i /dev/null >/dev/null 2>&1 || skip "no ssh-to-age on the host PATH"
  # The rest of this test runs with the host's PATH, so sops and ssh-to-age are the real binaries
  # and no stub writes the call log: the contract here is the passphrase input of ssh-to-age itself.
  PATH="$host_path"
  # Wrong passphrase first: exit 3, a reason, and nothing else — no identity, no temp file, no blob
  # on the terminal, so a retry starts clean and the secret never reaches the record channel.
  export SSH_TO_AGE_PASSPHRASE='not-the-passphrase'
  run ctl init --from-ssh "$stubs/ssh_protected"
  [ "$status" -eq 3 ]
  [[ $output == *"wrong passphrase?"* ]]
  [[ $output != *'protectpass'* ]]
  [[ $output != *'-----BEGIN'* ]]
  [ ! -e "$store4/keys.txt" ]
  unset SSH_TO_AGE_PASSPHRASE
  # A caller with no terminal is refused before the conversion, with the variable named.
  run ctl init --from-ssh "$stubs/ssh_protected" </dev/null
  [ "$status" -eq 3 ]
  [[ $output == *"SSH_TO_AGE_PASSPHRASE"* ]]
  [ ! -e "$store4/keys.txt" ]
  # Typed at the prompt (echo off). The redirect stays on `run`: a pipeline would run it in a
  # subshell, and bats' $status/$output would never reach this test.
  local pass_typed='protectpass'
  run ctl init --from-ssh "$stubs/ssh_protected" <<<"$pass_typed"
  [ "$status" -eq 0 ]
  [ -s "$store4/keys.txt" ]
  grep -q '^# created: ssh-to-age from ' "$store4/keys.txt"
  [ -s "$SOPS_RECIPIENTS" ]
  # The derived half seals a record that opens through the identity file alone: no flag, no key
  # command, which is the route credsctl and xilo hand off on.
  printf '{"token":"mock-token"}' >"$store4/a.sops.json"
  (cd "$store4" && sops -e a.sops.json) 2>/dev/null >"$store4/enc.sops.json"
  run ctl get token "$store4/enc.sops.json"
  [ "$status" -eq 0 ]
  [ "$output" = "mock-token" ]
}

@test "an unlocked ssh origin needs no terminal and no variable: the route stays automatic" {
  store5="$stubs/sshopen"
  mkdir -p "$store5"
  export SOPS_AGE_FILE="$store5/keys.txt" SOPS_RECIPIENTS="$store5/recipient"
  export SOPS_RULES="$store5/.sops.yaml"
  # Same reason as the test above: this one proves a real sops round trip through a derived
  # identity, so the stubs must not shadow sops or ssh-to-age.
  PATH="$host_path"
  run ctl init --from-ssh "$stubs/ssh_unlocked" </dev/null
  [ "$status" -eq 0 ]
  printf '{"u":"1"}' >"$store5/a.sops.json"
  (cd "$store5" && sops -e a.sops.json) 2>/dev/null >"$store5/enc.sops.json"
  run ctl get u "$store5/enc.sops.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "init --from-ssh reads both halves before it asks or converts" {
  chmod 000 "$stubs/ssh_protected.pub"
  run ctl init --from-ssh "$stubs/ssh_protected"
  chmod 600 "$stubs/ssh_protected.pub"
  [ "$status" -eq 2 ]
  [[ $output == *"both halves"* ]]
  [[ $output != *'passphrase for'* ]]
  run ! grep -q 'ssh-to-age' "$calls"
}
