#!/usr/bin/env bash
# features/hm-creds/sopsctl.sh against PATH stubs, plus one real-binary round trip.
#
# Contract under test: init keeps the secret half in an age identity file ($SOPS_AGE_FILE, sops'
# own default lookup) and the public half in the recipient file plus a .sops.yaml of creation rules
# beside the records; the key can also come from $SOPS_KEYS_CMD (sops calls it itself — no key file,
# no terminal), which stays the route for anyone who keeps a key in a wallet. Encrypt takes a PATH —
# a plaintext *.sops.yaml or *.sops.json file encrypted in place with recipients from that rules
# file (`--config`, so the cwd never matters) — or, with no PATH, reads json on stdin and writes
# ciphertext to stdout for credsctl; a record is a map in either
# shape sops supports (*.sops.json or *.sops.yaml — the suffix is the shape), whose OWN metadata
# names the recipients, so `set` re-encrypts to those and keeps the shape; the plaintext is always
# json, so jq reads both. `set` takes the new value from stdin — never an argument, since
# /proc/PID/cmdline is world-readable — and replaces the record, leaving it 0400 (sops --set writes
# in place, which a 0400
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
    # -i encrypts the file in place, as real sops does; without it the ciphertext goes to stdout.
    inplace=""
    for a in "\$@"; do [ "\$a" = "-i" ] && inplace=1; done
    if [ -n "\$inplace" ]; then
      case "\${@: -1}" in
        *.yaml) printf 'secret: ENC[AGE1,mock]\nsops:\n  age:\n    - recipient: age1fromrules\n' > "\${@: -1}" ;;
        *) printf '{"secret":"ENC[AGE1,mock]","sops":{"age":[{"recipient":"age1fromrules"}]}}\n' > "\${@: -1}" ;;
      esac
      exit 0
    fi
    jq -c '. + {sops: {age: [{recipient: "age1meta"}]}}' ;;
  -d)
    [ "\${SOPS_DECRYPT_EXIT:-0}" = 0 ] || exit "\$SOPS_DECRYPT_EXIT"
    path=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "--extract" ] && path="\$a"
      prev="\$a"
    done
    # A yaml record decrypts to json when sops is told to, as the real binary does; the stub models
    # that output so the json path is exercised without a yaml parser.
    case "\${@: -1}" in
      *.yaml) plain='{"secret":"s3cr3t","TOKEN":"abc"}' ;;
      *) plain=\$(jq -c 'del(.sops)' "\${@: -1}") ;;
    esac
    if [ -n "\$path" ]; then jq -r ".\$path" <<<"\$plain"; else printf '%s\n' "\$plain"; fi ;;
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
  printf '{"secret":"s3cr3t"}' | ctl encrypt --format json >"$record"
  chmod 400 "$record"
  # A yaml record, as a person or another tool would leave it: ciphertext lines plus the unencrypted
  # metadata that names the recipient. The stub reads it as json only when asked to.
  yaml_record="$store/XILO.sops.yaml"
  printf 'secret: ENC[AGE1,mock]\nTOKEN: ENC[AGE1,mock]\nsops:\n  age:\n    - recipient: age1meta\n' >"$yaml_record"
  chmod 400 "$yaml_record"

  # A real terminal on stdin, so a `-t 0` branch is exercised rather than assumed. This host has no
  # `script`, so python's pty is the only way to hand a child a tty. The runner kills the child after
  # 5s and reports 124, so a hang shows up as a failing status instead of a wedged suite.
  # `pty` imports the stdlib `tty` module, so the runner must not be named tty.py — python would
  # import this file instead of the stdlib.
  tty="$stubs/tty"
  py=$(command -v python3 || true)
  if [ -n "$py" ]; then
    cat >"$stubs/ptyrun.py" <<'EOF'
import os, pty, signal, subprocess, sys
master, slave = pty.openpty()
p = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, close_fds=True, start_new_session=True)
os.close(slave)
try:
    out, _ = p.communicate(timeout=3)
    code = p.returncode
except subprocess.TimeoutExpired:
    # Killing the child alone leaves its own children alive holding the stdout pipe open, so
    # reading to EOF would hang forever: kill the whole session.
    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    out = p.communicate()[0]
    code = 124
sys.stdout.buffer.write(out)
sys.exit(code)
EOF
    printf '#!/usr/bin/env bash\nexec "%s" "%s/ptyrun.py" "$@"\n' "$py" "$stubs" >"$tty"
    chmod +x "$tty"
  fi
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

# The rules file is sops-nix's shape: a `keys:` block of anchors and a `key_groups` entry, so one
# entry carries every recipient and a hand-written `sops -e FILE` needs no flag. It covers both
# record shapes, because `.sops.yaml` is the shape a person writes by hand.
@test "init seeds sops-nix creation rules carrying every recipient, for both record shapes" {
  run ctl init
  [ "$status" -eq 0 ]
  grep -q 'age1stub' "$SOPS_RECIPIENTS"
  grep -q '^keys:' "$rulefile"
  grep -q 'key_groups:' "$rulefile"
  grep -q '  - age:' "$rulefile"
  grep -qF '\.sops\.(json|yaml)$' "$rulefile"
  for r in age1aaa age1bbb age1stub; do grep -q "$r" "$rulefile"; done
  [ "$(grep -c -- '- \*' "$rulefile")" -eq 3 ]
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

# --- reset ------------------------------------------------------------------
# sopsctl owns four kinds of file: the identity, the rules file, the recipient file, and the records.
# `reset` names them so `init` starts fresh, and only --force deletes — the identity is the only thing
# that can read the records, so removing both is permanent. Only a `.cred` stays: systemd-creds, not
# sops, owns it.
@test "reset names the files it would remove and removes nothing without --force" {
  run ctl init
  printf 'secret: hunter2\n' >"$store/A.sops.yaml"
  printf '{"secret":"hunter2"}' >"$store/B.sops.json"
  printf 'plain\n' >"$store/C.cred"
  run ctl reset
  [ "$status" -eq 1 ]
  grep -q -- '--force' <<<"$output"
  grep -q "$SOPS_AGE_FILE" <<<"$output"
  grep -q "$rulefile" <<<"$output"
  grep -q "$store/recipient" <<<"$output"
  grep -q "$store/A.sops.yaml" <<<"$output"
  grep -q "$store/B.sops.json" <<<"$output"
  run ! grep -q "$store/C.cred" <<<"$output"
  [ -f "$SOPS_AGE_FILE" ]
  [ -f "$rulefile" ]
  [ -f "$store/recipient" ]
  [ -f "$store/A.sops.yaml" ]
  [ -f "$store/B.sops.json" ]
}

@test "reset --force removes identity, rules, recipients and both record shapes, and init then starts fresh" {
  run ctl init
  printf 'secret: hunter2\n' >"$store/A.sops.yaml"
  printf '{"secret":"hunter2"}' >"$store/B.sops.json"
  printf 'plain\n' >"$store/C.cred"
  run ctl reset --force
  [ "$status" -eq 0 ]
  [ ! -f "$SOPS_AGE_FILE" ]
  [ ! -f "$rulefile" ]
  [ ! -f "$store/recipient" ]
  [ ! -f "$store/A.sops.yaml" ]
  [ ! -f "$store/B.sops.json" ]
  [ -f "$store/C.cred" ]
  : >"$calls"
  run ctl init
  [ "$status" -eq 0 ]
  grep -q '^age-keygen -o ' "$calls"
  grep -q '^keys:' "$rulefile"
  grep -q '^age1stub' "$SOPS_RECIPIENTS" # the recipient file is written again, with the new key
  [ "$(stat -c '%a' "$SOPS_AGE_FILE")" = "600" ]
}

# Only sops' own directory is fair game. A custom $SOPS_AGE_FILE points somewhere sopsctl has no
# business deleting, so the identity file goes and its neighbours stay.
@test "reset --force deletes a custom identity file, not the directory that holds it" {
  d="$(mktemp -d)"
  mkdir -p "$d/wallet"
  printf 'AGE-SECRET-KEY-1TEST\n' >"$d/wallet/keys.txt"
  printf 'KEEP\n' >"$d/wallet/note.txt"
  export SOPS_AGE_FILE="$d/wallet/keys.txt"
  run ctl reset --force
  [ "$status" -eq 0 ]
  [ ! -f "$d/wallet/keys.txt" ]
  [ -f "$d/wallet/note.txt" ]
  rm -rf "$d"
}

@test "reset --force deletes sops' whole config directory when the identity is sops' default path" {
  home="$(mktemp -d)"
  export HOME="$home"
  export SOPS_AGE_FILE="$home/.config/sops/age/keys.txt"
  mkdir -p "$home/.config/sops/age"
  printf 'AGE-SECRET-KEY-1TEST\n' >"$home/.config/sops/age/keys.txt"
  printf 'KEEP\n' >"$home/.config/keep.txt"
  run ctl reset --force
  [ "$status" -eq 0 ]
  [ ! -d "$home/.config/sops" ]
  [ -f "$home/.config/keep.txt" ]
  rm -rf "$home"
}

@test "reset refuses an argument it does not know, and an empty environment says so" {
  run ctl reset --all
  [ "$status" -eq 1 ]
  grep -q -- '--force' <<<"$output"
  # setup already left records and a recipient file in the store, so "nothing to reset" needs an
  # empty directory of its own: the recipient file is one of the files reset names.
  empty="$(mktemp -d)"
  export SOPS_RECIPIENTS="$empty/recipient"
  export SOPS_AGE_FILE="$empty/keys.txt"
  run ctl reset --force
  [ "$status" -eq 0 ]
  grep -q 'nothing to reset' <<<"$output"
  rm -rf "$empty"
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

@test "encrypt defaults to a yaml record and takes recipients from the recipient file" {
  run ctl encrypt <<'EOF'
{"secret":"x"}
EOF
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type yaml --age age1aaa,age1bbb --config /dev/null /dev/stdin' "$calls"
}

@test "encrypt --format json writes a json record; --format yaml says the same as the default" {
  run ctl encrypt --format json <<'EOF'
{"secret":"x"}
EOF
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type json --age age1aaa,age1bbb --config /dev/null /dev/stdin' "$calls"
  : >"$calls"
  run ctl encrypt --format yaml <<'EOF'
{"secret":"x"}
EOF
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type yaml --age age1aaa,age1bbb --config /dev/null /dev/stdin' "$calls"
}

# A path argument is the plaintext to encrypt, in place — sops' own way (`sops -e -i FILE`). The
# rules file is named with --config so the recipients come from it whatever the cwd is, and the
# suffix is the shape, so a *.json file never becomes yaml.
@test "encrypt a plaintext yaml file in place, recipients from the rules file, record left 0400" {
  run ctl init
  : >"$calls"
  printf 'secret: hunter2\nTOKEN: abc\n' >"$store/PLAN.sops.yaml"
  chmod 600 "$store/PLAN.sops.yaml"
  run ctl encrypt "$store/PLAN.sops.yaml"
  [ "$status" -eq 0 ]
  grep -q "^sops -e -i --config $rulefile $store/PLAN.sops.yaml " "$calls"
  run ! grep -q '/dev/stdin' "$calls"
  run ! grep -q -- '--age' "$calls"
  grep -q 'ENC\[AGE1,mock\]' "$store/PLAN.sops.yaml"
  run ! grep -q 'hunter2' "$store/PLAN.sops.yaml"
  [ "$(stat -c '%a' "$store/PLAN.sops.yaml")" = "400" ]
}

@test "encrypt a plaintext json file the same way; a --format that contradicts the suffix is refused" {
  run ctl init
  : >"$calls"
  printf '{"secret":"hunter2"}\n' >"$store/PLAN.sops.json"
  run ctl encrypt "$store/PLAN.sops.json"
  [ "$status" -eq 0 ]
  grep -q "^sops -e -i --config $rulefile $store/PLAN.sops.json " "$calls"
  printf '{"secret":"hunter2"}\n' >"$store/B.sops.json"
  run ctl encrypt "$store/B.sops.json" --format yaml
  [ "$status" -eq 1 ]
  grep -qi 'json record' <<<"$output"
}

# No rules file yet: the recipient file is the fallback, so encrypt still names who can read it.
@test "encrypt with no rules file names recipients from the recipient file" {
  : >"$calls"
  printf 'secret: hunter2\n' >"$store/N.sops.yaml"
  run ctl encrypt "$store/N.sops.yaml"
  [ "$status" -eq 0 ]
  grep -q -- '--age age1aaa,age1bbb' "$calls"
}

# A record is immutable: re-encrypting one is `set` or `rekey`, not `encrypt`, and a path that is
# not a *.sops.json / *.sops.yaml file is not a record at all.
@test "encrypt refuses a file that is already a record and a path that is not one" {
  : >"$calls"
  run ctl encrypt "$record"
  [ "$status" -eq 1 ]
  grep -qi 'already' <<<"$output"
  run ctl encrypt "$yaml_record"
  [ "$status" -eq 1 ]
  run ctl encrypt "$store/loose.cred"
  [ "$status" -eq 2 ]
  run ctl encrypt "$store/nope.sops.yaml"
  [ "$status" -eq 2 ]
  run ! grep -q '^sops ' "$calls"
}

@test "encrypt refuses a format sops cannot write, and calls nothing" {
  : >"$calls"
  run ctl encrypt --format toml <<'EOF'
{"secret":"x"}
EOF
  [ "$status" -eq 1 ]
  grep -qi 'format' <<<"$output"
  run ! grep -q '^sops ' "$calls"
}

# A terminal is not a pipe. With no path and no stdin to read, sops sits on the tty forever, so
# encrypt says where the plaintext comes from and calls nothing — a hang shows up as status 124
# from the pty runner, not as a green test.
@test "encrypt on a terminal exits with guidance instead of waiting for input" {
  [ -x "$tty" ] || skip "no python3 to hand a terminal to the child"
  : >"$calls"
  run "$tty" bash "$script" encrypt --format yaml
  [ "$status" -eq 1 ]
  grep -qi 'stdin' <<<"$output"
  grep -qi 'credsctl' <<<"$output"
  run ! grep -q '^sops ' "$calls"
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
  grep -q '^sops -d --output-type json --extract \["secret"\] .*keycmd=kwallet-query -f flakeroot -r creds-identity kdewallet' "$calls"
}

# A scalar handed to a caller is json whatever the record's shape, so `get` never returns a quoted
# yaml string; the shape only matters for the whole-record print, which stays in the record's own shape.
@test "get reads a field out of a yaml record as the bare value" {
  run ctl get TOKEN "$yaml_record"
  [ "$status" -eq 0 ]
  [ "$output" = "abc" ]
  grep -q '^sops -d --output-type json --extract \["TOKEN"\]' "$calls"
}

# Decrypting is always json: the plaintext is fed to jq whatever the record's own shape is, so the
# one flag that makes a yaml record readable is always passed.
@test "decrypt prints json for a yaml record, with the same argv as for a json record" {
  : >"$calls"
  run ctl decrypt "$yaml_record"
  [ "$status" -eq 0 ]
  [ "$output" = '{"secret":"s3cr3t","TOKEN":"abc"}' ]
  grep -q "^sops -d --output-type json $yaml_record " "$calls"
  : >"$calls"
  run ctl decrypt "$record"
  grep -q "^sops -d --output-type json $record " "$calls"
}

@test "a missing record exits 2 and a failing decrypt exits 3" {
  run ctl get secret "$store/nope.sops.json"
  [ "$status" -eq 2 ]
  SOPS_DECRYPT_EXIT=128 run ctl decrypt "$record"
  [ "$status" -eq 3 ]
}

# A record shape is what makes a file readable here: a .cred belongs to systemd-creds, and sops has
# no format to read it with.
@test "a name with no record suffix is refused, without running sops" {
  printf 'cipher' >"$store/loose.cred"
  run ctl decrypt "$store/loose.cred"
  [ "$status" -eq 2 ]
  run ! grep -q '^sops -d' "$calls"
  run ctl get secret "$store/loose.cred"
  [ "$status" -eq 2 ]
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
# The new value is never an argument: /proc/PID/cmdline is world-readable (mode 0444 on this host),
# so a value passed as argv is readable by every user on the machine for the life of the process, and
# `jq --arg v` would have put it in a second argv too. It comes from stdin — an anonymous pipe with no
# path, so there is nothing to permission-check.
@test "set reads the new value from stdin, re-encrypts to the record's own recipients, and keeps the record 0400" {
  printf 'new-value' >"$stubs/value"
  run ctl set secret "$record" <"$stubs/value"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$record")" = "400" ]
  run ctl get secret "$record"
  [ "$output" = "new-value" ]
  grep -q '^sops -e --input-type json --output-type json --age age1meta --config /dev/null /dev/stdin' "$calls"
  run ! grep -q 'new-value' "$calls"
  run ! ls "$store"/TOKEN.sops.json.* >/dev/null 2>&1
}

# A value typed at a terminal is read with echo off, the same rule credsctl encrypt uses; an
# argument-shaped value is refused rather than quietly accepted.
@test "set refuses a value as an argument and an empty value, and leaves the record untouched" {
  run ctl set secret "new-value" "$record"
  [ "$status" -eq 1 ]
  grep -q 'the new value comes from stdin' <<<"$output"
  before=$(sha256sum <"$record")
  run ctl set secret "$record" </dev/null
  [ "$status" -eq 1 ]
  grep -q 'empty value' <<<"$output"
  [ "$(sha256sum <"$record")" = "$before" ]
}

@test "set refuses a field name that is not usable and a record with no recipients" {
  run ctl set 'bad field' "$record"
  [ "$status" -eq 1 ]
  printf '{"secret":"x"}' >"$store/RAW.sops.json"
  chmod 400 "$store/RAW.sops.json"
  printf 'v' >"$stubs/value"
  run ctl set secret "$store/RAW.sops.json" <"$stubs/value"
  [ "$status" -eq 3 ]
}

@test "rekey re-encrypts records to the recipient file" {
  : >"$calls"
  run ctl rekey "$record"
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type json --age age1aaa,age1bbb --config /dev/null /dev/stdin' "$calls"
  run ctl get secret "$record"
  [ "$output" = "s3cr3t" ]
}

# A yaml record keeps its own shape through a change: decrypting for jq is json, writing back is yaml,
# and the recipients come from the record's own unencrypted metadata — not from a rules file.
@test "set on a yaml record decrypts as json, re-encrypts as yaml, and stays 0400" {
  : >"$calls"
  printf 'new-value' >"$stubs/value"
  run ctl set TOKEN "$yaml_record" <"$stubs/value"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$yaml_record")" = "400" ]
  grep -q "^sops -d --output-type json $yaml_record " "$calls"
  grep -q '^sops -e --input-type json --output-type yaml --age age1meta --config /dev/null /dev/stdin' "$calls"
  run ! grep -q 'new-value' "$calls"
  run ! ls "$store"/XILO.sops.yaml.* >/dev/null 2>&1
}

# rekey is the rotation: the recipients come from $SOPS_RECIPIENTS, not from the record, and the
# shape the record already has is kept.
@test "rekey on a yaml record keeps it yaml and re-encrypts to the recipient file" {
  : >"$calls"
  run ctl rekey "$yaml_record"
  [ "$status" -eq 0 ]
  grep -q '^sops -e --input-type json --output-type yaml --age age1aaa,age1bbb --config /dev/null /dev/stdin' "$calls"
}

@test "recipients of a yaml record are read from its metadata, without decrypting" {
  run ctl recipients "$yaml_record"
  [ "$status" -eq 0 ]
  [ "$output" = "age1meta" ]
  run ! grep -q '^sops -d' "$calls"
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
  printf '~/home' >"$stubs/tilde-value"
  run ctl set secret "$record" <"$stubs/tilde-value"
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
  cipher=$(jq -n --arg v "$(printf 'line1\nline2')" '{secret:$v}' | ctl encrypt --format json)
  printf '%s' "$cipher" >"$store2/A.sops.json"
  chmod 400 "$store2/A.sops.json"
  run ctl get secret "$store2/A.sops.json"
  [ "$status" -eq 0 ]
  [ "$output" = "line1
line2" ]
  run ctl verify "$store2/A.sops.json"
  [ "$status" -eq 0 ]
  printf 'second' >"$stubs/v2"
  run ctl set secret "$store2/A.sops.json" <"$stubs/v2"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$store2/A.sops.json")" = "400" ]
  run ctl get secret "$store2/A.sops.json"
  [ "$output" = "second" ]
  # A piped value keeps its inner newlines; only the trailing one is dropped, as encrypt does.
  printf 'a\nb\n' >"$stubs/v3"
  run ctl set secret "$store2/A.sops.json" <"$stubs/v3"
  [ "$status" -eq 0 ]
  [ "$(ctl get secret "$store2/A.sops.json")" = "$(printf 'a\nb')" ]
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
  # The same rules entry covers a hand-made yaml record, which is what a person edits by hand.
  printf 'A: "1"' >"$store3/a.sops.yaml"
  (cd "$store3" && sops -e a.sops.yaml) 2>/dev/null >"$store3/enc.sops.yaml"
  grep -q '^A: ENC\[AES256_GCM,data:' "$store3/enc.sops.yaml"
  run ctl get A "$store3/enc.sops.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  sed -i 's/ENC\[AES256_GCM,data:[A-Za-z0-9+/]\{4\}/ENC[AES256_GCM,data:XXXX/' "$store2/A.sops.json"
  run ctl verify "$store2/A.sops.json"
  [ "$status" -eq 3 ]
}

# The yaml shape, end to end with the real sops and a mock key: ciphertext stays yaml, a change stays
# yaml, and every read still comes back as json for jq — no yaml parser anywhere in sopsctl.
@test "real sops round trip through the yaml shape: encrypt, read, set, rekey all stay yaml" {
  PATH="$host_path" command -v sops >/dev/null 2>&1 || skip "no sops on the host PATH"
  PATH="$host_path" command -v age-keygen >/dev/null 2>&1 || skip "no age-keygen on the host PATH"
  PATH="$host_path"
  store4="$stubs/real-yaml"
  mkdir -p "$store4"
  age-keygen -o "$stubs/realkey4" 2>/dev/null || skip "age-keygen failed"
  grep '^# public key:' "$stubs/realkey4" | awk '{print $NF}' >"$store4/recipient"
  export SOPS_RECIPIENTS="$store4/recipient"
  export SOPS_AGE_FILE="$stubs/realkey4"
  jq -n --arg s "$(printf 'one\nTwo\n')" --arg t 'abc' '{secret:$s,TOKEN:$t}' |
    ctl encrypt >"$store4/B.sops.yaml"
  chmod 400 "$store4/B.sops.yaml"
  grep -q '^secret: ENC\[AES256_GCM,data:' "$store4/B.sops.yaml"
  run ctl get TOKEN "$store4/B.sops.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "abc" ]
  run ctl decrypt "$store4/B.sops.yaml"
  [ "$status" -eq 0 ]
  [ "$(jq -r .secret <<<"$output")" = "$(printf 'one\nTwo\n')" ]
  printf 'second' >"$stubs/v4"
  run ctl set TOKEN "$store4/B.sops.yaml" <"$stubs/v4"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$store4/B.sops.yaml")" = "400" ]
  grep -q '^TOKEN: ENC\[AES256_GCM,data:' "$store4/B.sops.yaml"
  run ! grep -q 'second' "$store4/B.sops.yaml"
  run ctl get TOKEN "$store4/B.sops.yaml"
  [ "$output" = "second" ]
  # Rotation: a second age keypair in the recipient file, so the record re-seals to a key the
  # identity in SOPS_AGE_FILE no longer matches — a real sops refuses a malformed recipient outright.
  age-keygen -o "$stubs/realkey4b" 2>/dev/null || skip "age-keygen failed"
  grep '^# public key:' "$stubs/realkey4b" | awk '{print $NF}' >"$store4/recipient"
  other="$(cat "$store4/recipient")"
  run ctl rekey "$store4/B.sops.yaml"
  [ "$status" -eq 0 ]
  grep -q "recipient: $other" "$store4/B.sops.yaml"
  run ctl get TOKEN "$store4/B.sops.yaml"
  [ "$status" -eq 3 ]
}

# The file path is the input, the rules file beside the records is what names the recipients, and
# neither depends on the cwd: this runs from the repo root against a store under /tmp.
@test "real sops encrypts a plaintext yaml record in place from the rules file and reads it back" {
  PATH="$host_path" command -v sops >/dev/null 2>&1 || skip "no sops on the host PATH"
  PATH="$host_path" command -v age-keygen >/dev/null 2>&1 || skip "no age-keygen on the host PATH"
  PATH="$host_path"
  store5="$stubs/file-mode"
  mkdir -p "$store5"
  age-keygen -o "$stubs/realkey5" 2>/dev/null || skip "age-keygen failed"
  grep '^# public key:' "$stubs/realkey5" | awk '{print $NF}' >"$store5/recipient"
  export SOPS_RECIPIENTS="$store5/recipient"
  export SOPS_AGE_FILE="$store5/keys.txt"
  run ctl init
  [ "$status" -eq 0 ]
  printf 'TOKEN: "abc"\nhost_unencrypted: prod\n' >"$store5/XILO.sops.yaml"
  chmod 600 "$store5/XILO.sops.yaml"
  run ctl encrypt "$store5/XILO.sops.yaml"
  [ "$status" -eq 0 ]
  grep -q '^TOKEN: ENC\[AES256_GCM,data:' "$store5/XILO.sops.yaml"
  # sops keeps a *_unencrypted field readable, so a name or a URL stays in the clear.
  grep -q '^host_unencrypted: prod$' "$store5/XILO.sops.yaml"
  run ! grep -q '"abc"' "$store5/XILO.sops.yaml"
  [ "$(stat -c '%a' "$store5/XILO.sops.yaml")" = "400" ]
  run ctl get TOKEN "$store5/XILO.sops.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "abc" ]
  run ctl recipients "$store5/XILO.sops.yaml"
  [ "$output" = "$(cat "$store5/recipient")" ]
  # Re-encrypting a record is `set` or `rekey`, never encrypt.
  run ctl encrypt "$store5/XILO.sops.yaml"
  [ "$status" -eq 1 ]
  # The json shape goes through the same rules entry.
  printf '{"secret":"hunter2"}\n' >"$store5/A.sops.json"
  run ctl encrypt "$store5/A.sops.json"
  [ "$status" -eq 0 ]
  grep -q '"secret": "ENC\[AES256_GCM' "$store5/A.sops.json"
  run ctl get secret "$store5/A.sops.json"
  [ "$output" = "hunter2" ]
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
