#!/usr/bin/env bash
# The `sh -c '...'` snippets in this file must reach sh unexpanded: $ALPHA is sh's variable, not
# this test's, so the single quotes are deliberate.
# shellcheck disable=SC2016
# features/hm-creds/credsctl.sh against PATH stubs plus one real round-trip per backend.
#
# Contract under test: a record is one file in $CREDS_DIR; the extension picks the backend
# (<name>.cred = systemd-creds, one secret per file; <name>.sops.json = sops through sopsctl, and a
# sops record may hold several secrets as fields whose names are environment variables); records are
# immutable, so encrypt never overwrites and always writes 0400 — a change is remove + re-add;
# plaintext only ever goes to stdout. A name may carry its backend suffix: the suffix picks the
# backend, it is not part of the record's identity. Exit codes: 1 usage, 2 no such record,
# 3 encrypt or decrypt failed.
#
# credsctl does no sops plumbing of its own — the .sops.json branch is a delegation to sopsctl, so
# this suite asserts what sopsctl is handed, not how sops is called (tests/sopsctl.bats does that).
# Stubs record argv so the flags systemd-creds/sopsctl actually receive are asserted, not grepped for.
# The real-tier tests run on the host PATH with the stub dir removed; they skip when the real
# binaries are absent.

load helpers

setup() {
  harness_stub_dir
  export CALLS="$calls"
  script="$repo/features/hm-creds/credsctl.sh"
  creds="$stubs/creds"
  mkdir -p "$creds"

  stub systemd-creds <<'EOF'
#!/usr/bin/env bash
echo "systemd-creds $*" >> "$CALLS"
case "$1" in
  encrypt)
    [ "$2" = "--user" ] && [ "$3" = "--name" ] || exit 9
    [ "${SC_ENCRYPT_EXIT:-0}" = 0 ] || exit "$SC_ENCRYPT_EXIT"
    cat > "${@: -1}" ;;
  decrypt)
    [ "$2" = "--user" ] && [ "$3" = "--name" ] || exit 9
    if [ "${SC_DECRYPT_EXIT:-0}" != 0 ]; then echo "stub: cannot decrypt" >&2; exit "$SC_DECRYPT_EXIT"; fi
    cat "${@: -1}" ;;
  list)
    [ "$2" = "--user" ] || exit 9
    if [ -n "${SC_LIST_OUT:-}" ]; then printf '%s\n' "${SC_LIST_OUT}"; fi ;;
  *) exit 9 ;;
esac
EOF
  # The portable backend is a delegation: sopsctl owns the sops flags, the recipients and the key
  # command, so this stub only has to behave like a record store — encrypt reads json on stdin and
  # writes ciphertext on stdout, decrypt prints the record's plaintext json (one process per
  # record, which is what makes a multi-field record worth having).
  stub sopsctl <<'EOF'
#!/usr/bin/env bash
echo "sopsctl $*" >> "$CALLS"
one_record='{"secret":"stub-plain"}'
case "$1" in
  encrypt)
    [ "${SOPS_ENCRYPT_EXIT:-0}" = 0 ] || exit "${SOPS_ENCRYPT_EXIT}"
    cat ;;
  decrypt)
    [ "${SOPS_DECRYPT_EXIT:-0}" = 0 ] || { echo "sopsctl: cannot decrypt ${@: -1}" >&2; exit "${SOPS_DECRYPT_EXIT}"; }
    printf '%s' "${SOPS_JSON:-$one_record}" ;;
  *) exit 9 ;;
esac
EOF
  export CREDS_DIR="$creds"
  PATH="$stubs:$PATH"
}


# Encrypt fixture: credsctl reads the secret on stdin, so every encrypt site redirects from one
# file. printf keeps the bytes exactly — no trailing newline, which is what record contents are
# asserted against.
write_in() { printf '%s' "$1" >"$stubs/in"; }

ctl() { bash "$script" "$@"; }

# --- list -------------------------------------------------------------------

# systemd-creds only ever reports its own store (~/.local/share/credentials). Listing that store
# alongside $CREDS_DIR is only honest when they are the same directory; when CREDS_DIR points
# elsewhere, the records there are listed here and systemd's store is not reported at all.
@test "list on systemd's own store shows systemd's lines plus the age records, once each" {
  store="$stubs/home/.local/share/credentials"
  mkdir -p "$store"
  printf 'cipher' >"$store/alpha.cred"
  printf 'cipher' >"$store/beta.sops.json"
  SC_LIST_OUT="alpha.cred secure 6B $store/alpha.cred" \
    run env HOME="$stubs/home" CREDS_DIR="$store" bash "$script" list
  [ "$status" -eq 0 ]
  grep -q 'alpha.cred secure' <<<"$output"
  grep -q 'beta.sops.json' <<<"$output"
  grep -q '^systemd-creds list --user' "$calls"
  [ "$(grep -c 'alpha.cred' <<<"$output")" = 1 ]
}

@test "list on an overridden CREDS_DIR lists that directory and asks systemd for nothing" {
  printf 'cipher' >"$creds/alpha.cred"
  printf 'cipher' >"$creds/beta.sops.json"
  printf 'cipher' >"$creds/gamma.sops.yaml"
  run ctl list
  [ "$status" -eq 0 ]
  grep -q 'alpha.cred .* insecure' <<<"$output"
  grep -q 'beta.sops.json .* insecure' <<<"$output"
  grep -q 'gamma.sops.yaml .* insecure' <<<"$output"
  [ "$(grep -c 'systemd-creds list' "$calls")" = 0 ]
}

# The rules file sopsctl init writes sits beside the records and is not a record: a list must not
# report it, and an empty store must still exit 0.
@test "list never reports the rules file beside the records" {
  printf 'cipher' >"$creds/gamma.sops.yaml"
  cat >"$creds/.sops.yaml" <<'EOF'
creation_rules:
  - path_regex: .*\.sops\.yaml$
    age: "age1aaa"
EOF
  run ctl list
  [ "$status" -eq 0 ]
  [ "$(grep -c 'sops.yaml' <<<"$output")" = 1 ]
  ! grep -q '^\.sops\.yaml ' <<<"$output"
}

@test "list on an empty store exits 0 and names nothing" {
  run ctl list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# The store location is one chain in credsctl: CREDS_DIR wins, then CREDENTIALS_DIRECTORY (what
# systemd sets for generated credentials), then systemd's own store. Every caller reads that.
@test "CREDENTIALS_DIRECTORY names the store and CREDS_DIR wins over it" {
  mkdir -p "$stubs/sys" "$stubs/other"
  touch "$stubs/sys/token.sops.json"
  touch "$stubs/other/other.sops.json"
  run env -u CREDS_DIR CREDENTIALS_DIRECTORY="$stubs/sys" bash "$script" list
  grep -q 'token.sops.json' <<<"$output"
  assert_no_out 'other.sops.json'
  run env CREDS_DIR="$stubs/other" CREDENTIALS_DIRECTORY="$stubs/sys" bash "$script" list
  grep -q 'other.sops.json' <<<"$output"
  assert_no_out 'token.sops.json'
}

# CREDS_ROOT is the third rung of that chain: it names the whole store for a flake-deployed secrets
# dir (./secrets in a flake checkout), and sopsctl's recipient and rules files follow the same root,
# so records, recipients and rules stay in one place. CREDS_DIR and CREDENTIALS_DIRECTORY still win.
@test "CREDS_ROOT names the store for a flake-deployed secrets dir, and the vars above it win" {
  mkdir -p "$stubs/flake" "$stubs/sys" "$stubs/other"
  touch "$stubs/flake/token.sops.json"
  touch "$stubs/sys/sys.sops.json"
  touch "$stubs/other/other.sops.json"
  # A host session may carry CREDENTIALS_DIRECTORY of its own, so the root tests clear it.
  run env -u CREDS_DIR -u CREDENTIALS_DIRECTORY CREDS_ROOT="$stubs/flake" bash "$script" list
  grep -q 'token.sops.json' <<<"$output"
  assert_no_out 'other.sops.json'
  run env -u CREDS_DIR CREDS_ROOT="$stubs/flake" CREDENTIALS_DIRECTORY="$stubs/sys" bash "$script" list
  grep -q 'sys.sops.json' <<<"$output"
  assert_no_out 'token.sops.json'
  run env CREDS_DIR="$stubs/other" CREDS_ROOT="$stubs/flake" bash "$script" list
  grep -q 'other.sops.json' <<<"$output"
  assert_no_out 'token.sops.json'
}

# --- encrypt ----------------------------------------------------------------

@test "encrypt writes a .cred record and passes --user --name, not a derived name" {
  write_in 'secret'
  run ctl encrypt ALPHA <"$stubs/in"
  [ "$status" -eq 0 ]
  grep -q "^systemd-creds encrypt --user --name ALPHA - $creds/ALPHA.cred$" "$calls"
  [ "$(stat -c '%a' "$creds/ALPHA.cred")" = "400" ]
}

# The secret reaches sopsctl as a json field, because a sops record is a map and sops encrypts every
# value in it; credsctl keeps the one-secret-per-record contract by writing exactly one field.
@test "encrypt NAME.sops.json delegates to sopsctl and stores the secret as a json field" {
  write_in 'secret'
  run ctl encrypt BETA.sops.json <"$stubs/in"
  [ "$status" -eq 0 ]
  grep -q '^sopsctl encrypt --format json$' "$calls"
  [ "$(cat "$creds/BETA.sops.json")" = '{"secret":"secret"}' ]
  [ "$(stat -c '%a' "$creds/BETA.sops.json")" = "400" ]
}

# The suffix is the record's shape, not a format request on the wire: sopsctl's own default is yaml,
# so credsctl names the format the suffix says.
@test "encrypt NAME.sops.yaml delegates with --format yaml and stores the secret as a field" {
  write_in 'secret'
  run ctl encrypt GAMMA.sops.yaml <"$stubs/in"
  [ "$status" -eq 0 ]
  grep -q '^sopsctl encrypt --format yaml$' "$calls"
  [ "$(cat "$creds/GAMMA.sops.yaml")" = '{"secret":"secret"}' ]
  [ "$(stat -c '%a' "$creds/GAMMA.sops.yaml")" = "400" ]
}

# Both backends land inside the root, so a flake-deployed store is one directory, not two: a .cred
# here and a sops record next to the recipient file sopsctl reads.
@test "encrypt with CREDS_ROOT writes both backends into that store" {
  write_in 'secret'
  run env -u CREDS_DIR -u CREDENTIALS_DIRECTORY CREDS_ROOT="$stubs/flake" bash "$script" encrypt ALPHA <"$stubs/in"
  [ "$status" -eq 0 ]
  grep -q "^systemd-creds encrypt --user --name ALPHA - $stubs/flake/ALPHA.cred$" "$calls"
  [ "$(stat -c '%a' "$stubs/flake/ALPHA.cred")" = "400" ]
  run env -u CREDS_DIR -u CREDENTIALS_DIRECTORY CREDS_ROOT="$stubs/flake" bash "$script" encrypt DELTA.sops.json <"$stubs/in"
  [ "$status" -eq 0 ]
  [ "$(cat "$stubs/flake/DELTA.sops.json")" = '{"secret":"secret"}' ]
  [ "$(stat -c '%a' "$stubs/flake/DELTA.sops.json")" = "400" ]
  run ! [ -e "$creds/ALPHA.cred" ] # the CREDS_DIR store was never written to
}

# One CREDS_ROOT means one directory in both tools: a quoted ~ reaches credsctl literal, exactly as
# it reaches sopsctl, so it expands here the same way. The quoted ~ is deliberate.
# shellcheck disable=SC2088
@test "a quoted CREDS_ROOT reaches the store as a real path" {
  home="$stubs/home2"
  mkdir -p "$home"
  write_in 'secret'
  run env -u CREDS_DIR -u CREDENTIALS_DIRECTORY HOME="$home" CREDS_ROOT='~/secrets' bash "$script" encrypt ALPHA <"$stubs/in"
  [ "$status" -eq 0 ]
  [ -f "$home/secrets/ALPHA.cred" ]
  run ! [ -e "$stubs/secrets" ]
}

@test "encrypt never overwrites: a record is removed and re-added to change it" {
  printf 'one' >"$stubs/one"
  printf 'two' >"$stubs/two"
  run ctl encrypt ALPHA <"$stubs/one"
  run ctl encrypt ALPHA <"$stubs/two"
  [ "$status" -eq 1 ]
  grep -qi 'remove' <<<"$output"
  [ "$(cat "$creds/ALPHA.cred")" = "one" ]
  [ "$(grep -c '^systemd-creds encrypt' "$calls")" = "1" ]
}

# The backend suffix may be spelled on the name; it names the backend, it is not part of the
# record's identity, so the three spellings are the same record.
@test "encrypt NAME.cred writes NAME.cred and decrypt resolves it under either spelling" {
  write_in 'secret'
  run ctl encrypt ALPHA.cred <"$stubs/in"
  [ "$status" -eq 0 ]
  [ -e "$creds/ALPHA.cred" ]
  [ ! -e "$creds/ALPHA.cred.cred" ]
  grep -q "^systemd-creds encrypt --user --name ALPHA - $creds/ALPHA.cred$" "$calls"
  run ctl decrypt ALPHA
  [ "$output" = "secret" ]
  run ctl decrypt ALPHA.cred
  [ "$output" = "secret" ]
  run ctl rm ALPHA.cred
  [ ! -e "$creds/ALPHA.cred" ]
}

@test "encrypt NAME.sops.json keeps the credential ID free of the suffix" {
  write_in 'secret'
  run ctl encrypt BETA.sops.json <"$stubs/in"
  [ ! -e "$creds/BETA.sops.json.sops.json" ]
  run ctl decrypt BETA.sops.json
  [ "$output" = "stub-plain" ]
  grep -q "^sopsctl decrypt $creds/BETA.sops.json\$" "$calls"
}

# A yaml record is read through the same one decrypt: sopsctl normalizes the plaintext to json, so
# credsctl's jq path never sees a yaml shape.
@test "encrypt NAME.sops.yaml keeps the credential ID free of the suffix and reads back as json" {
  write_in 'secret'
  run ctl encrypt GAMMA.sops.yaml <"$stubs/in"
  [ ! -e "$creds/GAMMA.sops.yaml.sops.yaml" ]
  SOPS_JSON='{"secret":"yaml-plain"}' run ctl decrypt GAMMA
  [ "$output" = "yaml-plain" ]
  grep -q "^sopsctl decrypt $creds/GAMMA.sops.yaml\$" "$calls"
  run ctl rm GAMMA.sops.yaml
  [ ! -e "$creds/GAMMA.sops.yaml" ]
}

# --- encrypt --fields: a bundle record ----------------------------------------

# A bundle is one sops record holding several secrets, its field names being the environment
# variables they are handed to. One decrypt then covers all of them, which is why the portable
# backend beats one .cred per secret (~23ms total instead of ~1.2s each). Values keep their
# newlines: jq writes them escaped, sops encrypts the escapes, decrypt returns real newlines.
@test "encrypt NAME.sops.json --fields writes a bundle record from a json object" {
  want=$'{"XILO_CACHE":"acme/pkgs","XILO_TOKEN":"tok\\nmulti\\nline","XILO_URL":"https://xilo.test"}'
  jq -S -n --arg u 'https://xilo.test' --arg c 'acme/pkgs' --arg t $'tok\nmulti\nline' \
    '{XILO_URL:$u,XILO_CACHE:$c,XILO_TOKEN:$t}' >"$stubs/fields"
  run ctl encrypt XILO.sops.json --fields "$stubs/fields"
  [ "$status" -eq 0 ]
  [ "$(cat "$creds/XILO.sops.json")" = "$want" ]
  grep -q '^sopsctl encrypt --format json$' "$calls"
  [ "$(stat -c '%a' "$creds/XILO.sops.json")" = "400" ]
}

@test "encrypt NAME.sops.yaml --fields writes a bundle record in the yaml shape" {
  jq -n --arg u 'https://xilo.test' --arg t $'tok\nmulti\nline' '{XILO_URL:$u,XILO_TOKEN:$t}' >"$stubs/fields"
  run ctl encrypt XILO.sops.yaml --fields "$stubs/fields"
  [ "$status" -eq 0 ]
  grep -q '^sopsctl encrypt --format yaml$' "$calls"
  [ "$(jq -S -c . "$creds/XILO.sops.yaml")" = '{"XILO_TOKEN":"tok\nmulti\nline","XILO_URL":"https://xilo.test"}' ]
  [ "$(stat -c '%a' "$creds/XILO.sops.yaml")" = "400" ]
}

@test "encrypt --fields reads a piped object and the marker may sit before the name" {
  run ctl encrypt --fields PAIR.sops.json <<<'{"A":"one","B":"two"}'
  [ "$status" -eq 0 ]
  [ "$(jq -S -c . "$creds/PAIR.sops.json")" = '{"A":"one","B":"two"}' ]
}

# Validation happens before anything is encrypted: a value that is not a secret, or a key no shell
# can name, is a usage error, not a record that decrypts to nothing.
@test "encrypt --fields refuses values that are not secrets" {
  printf '{"A":1}' >"$stubs/number"
  printf '{"A":""}' >"$stubs/emptyvalue"
  printf '{"my.token":"x"}' >"$stubs/dotted"
  printf '{"sops":"x"}' >"$stubs/metadata"
  printf '[{"A":"x"}]' >"$stubs/array"
  printf '{}' >"$stubs/nokeys"
  for f in number emptyvalue dotted metadata array nokeys; do
    run ctl encrypt BAD.sops.json --fields "$stubs/$f"
    [ "$status" -eq 1 ]
    grep -q 'fields must be' <<<"$output"
  done
  [ ! -e "$creds/BAD.sops.json" ]
}

@test "encrypt --fields is refused on a .cred name and never overwrites a bundle" {
  printf '{"A":"one"}' >"$stubs/fields"
  run ctl encrypt ALPHA --fields "$stubs/fields"
  [ "$status" -eq 1 ]
  grep -qi '\.sops' <<<"$output"
  [ ! -e "$creds/ALPHA.cred" ]
  run ctl encrypt XILO.sops.json --fields "$stubs/fields"
  run ctl encrypt XILO.sops.json --fields "$stubs/fields"
  [ "$status" -eq 1 ]
  grep -qi 'remove' <<<"$output"
  [ "$(cat "$creds/XILO.sops.json")" = '{"A":"one"}' ]
}

# A json object has no prompt path: typed at a terminal it would be echoed, so --fields needs the
# object piped or in a file. The pty proves the refusal instead of trusting the guard clause.
@test "encrypt --fields refuses a terminal instead of echoing a secret" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run python3 - "$script" "$creds" <<'PY'
import os, pty, select, sys, time
script, creds = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["CREDS_DIR"] = creds
    os.execv("/usr/bin/bash", ["bash", script, "encrypt", "TTYED.sops.json", "--fields"])
seen = b""
deadline = time.time() + 5
while time.time() < deadline:
    if not select.select([fd], [], [], 1)[0]:
        break
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    seen += chunk
_, status = os.waitpid(pid, 0)
print("status=%d" % os.WEXITSTATUS(status))
print(seen.decode(errors="replace"))
PY
  [ "$status" -eq 0 ]
  grep -q '^status=1$' <<<"$output"
  grep -qi 'piped\|file' <<<"$output"
  [ ! -e "$creds/TTYED.sops.json" ]
}

# A failing backend must not leave an empty record behind: the redirect creates the file before the
# backend runs, so a failed encrypt has to remove it. Any non-zero status lands in the same branch —
# the stub's own failure exit, and a delegate that exits 9, since a deployed generation puts a real
# sopsctl on PATH.
@test "encrypt a failing backend exits 3 and leaves no record" {
  write_in 'secret'
  SC_ENCRYPT_EXIT=1 run ctl encrypt ALPHA <"$stubs/in"
  [ "$status" -eq 3 ]
  [ ! -e "$creds/ALPHA.cred" ]
  SOPS_ENCRYPT_EXIT=1 run ctl encrypt BETA.sops.json <"$stubs/in"
  [ "$status" -eq 3 ]
  [ ! -e "$creds/BETA.sops.json" ]
  stub sopsctl <<'EOF'
#!/usr/bin/env bash
echo "delegate boom" >&2
exit 9
EOF
  run env CREDS_DIR="$creds" bash "$script" encrypt DELTA.sops.json <"$stubs/in"
  [ "$status" -eq 3 ]
  [ ! -e "$creds/DELTA.sops.json" ]
}

@test "encrypt takes a file argument as well as stdin" {
  printf 'from-file' >"$stubs/src"
  run ctl encrypt GAMMA "$stubs/src"
  [ "$status" -eq 0 ]
  [ "$(cat "$creds/GAMMA.cred")" = "from-file" ]
}

@test "encrypt takes one credential at a time" {
  run ctl encrypt ALPHA BETA EXTRA
  [ "$status" -eq 1 ]
  grep -q 'one credential at a time' <<<"$output"
  [ ! -e "$creds/ALPHA.cred" ]
}

@test "encrypt refuses an empty secret and a name that is not a credential ID" {
  : >"$stubs/empty"
  run ctl encrypt EMPTY <"$stubs/empty"
  [ "$status" -eq 1 ]
  run ctl encrypt 'bad/name'
  [ "$status" -eq 1 ]
  run ctl encrypt '.hidden'
  [ "$status" -eq 1 ]
  [ ! -e "$creds/EMPTY.cred" ]
}

@test "encrypt on a terminal prompts for the secret and never echoes it back" {
  # The prompt branch is `[[ -t 0 ]]`, so this needs a real pty: read the prompt first, then type
  # the secret, and check the terminal never shows it. Writing before the prompt would echo it --
  # the tty driver echoes at write time, and `read -s` only turns echo off once it is called.
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run python3 - "$script" "$creds" <<'PY'
import os, pty, select, sys
script, creds = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["CREDS_DIR"] = creds
    os.execv("/usr/bin/bash", ["bash", script, "encrypt", "TTYED"])
seen = b""
while b"secret for TTYED:" not in seen:
    if not select.select([fd], [], [], 5)[0]:
        break
    seen += os.read(fd, 1024)
os.write(fd, b"hunter2\n")
chunks = [seen]
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    chunks.append(chunk)
_, status = os.waitpid(pid, 0)
text = b"".join(chunks).decode(errors="replace")
print(f"pty exit={os.waitstatus_to_exitcode(status)} output={text.strip()}")
PY
  [ "$status" -eq 0 ]
  grep -q 'pty exit=0' <<<"$output"
  grep -q 'secret for TTYED:' <<<"$output"
  assert_no_out 'hunter2'
  [ -e "$creds/TTYED.cred" ]
  run ctl decrypt TTYED
  [ "$output" = "hunter2" ]
}

# --- decrypt ----------------------------------------------------------------

@test "decrypt takes several names and prints one record per line" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  run ctl decrypt ALPHA BETA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher
stub-plain" ]
}

@test "decrypt --env prints KEY=VALUE with the credential name as the key" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  run ctl decrypt --env ALPHA BETA
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA=cipher
BETA=stub-plain" ]
}

@test "decrypt with no name is a usage error" {
  run ctl decrypt
  [ "$status" -eq 1 ]
  grep -q 'decrypt needs at least one credential name' <<<"$output"
}

# --- rm ---------------------------------------------------------------------

@test "rm removes several credentials in one call and touches no backend" {
  printf 'cipher' >"$creds/ALPHA.cred"
  printf 'cipher' >"$creds/BETA.sops.json"
  printf 'cipher' >"$creds/GAMMA.cred"
  run ctl rm ALPHA BETA GAMMA
  [ "$status" -eq 0 ]
  [ ! -e "$creds/ALPHA.cred" ]
  [ ! -e "$creds/BETA.sops.json" ]
  [ ! -e "$creds/GAMMA.cred" ]
  [ ! -s "$calls" ]
}

@test "rm with a name that has no record removes nothing at all and exits 2" {
  printf 'cipher' >"$creds/ALPHA.cred"
  printf 'cipher' >"$creds/BETA.cred"
  run ctl rm ALPHA GHOST
  [ "$status" -eq 2 ]
  [ -e "$creds/ALPHA.cred" ]
  [ -e "$creds/BETA.cred" ]
}

@test "rm on a repeated name deletes the record once and succeeds" {
  printf 'cipher' >"$creds/ALPHA.cred"
  run ctl rm ALPHA ALPHA
  [ "$status" -eq 0 ]
  [ ! -e "$creds/ALPHA.cred" ]
}

@test "rm refuses a name that resolves to more than one record" {
  printf 'cipher' >"$creds/EPSILON.cred"
  printf 'cipher' >"$creds/EPSILON.sops.json"
  printf 'cipher' >"$creds/EPSILON.sops.yaml"
  run ctl rm EPSILON
  [ "$status" -eq 1 ]
  grep -q 'more than one record for EPSILON' <<<"$output"
  grep -q 'EPSILON.sops.yaml' <<<"$output"
  [ -e "$creds/EPSILON.cred" ]
}

@test "rm with no name is a usage error" {
  run ctl rm
  [ "$status" -eq 1 ]
  grep -q 'rm needs at least one credential name' <<<"$output"
}

@test "decrypt resolves the .cred backend and prints to stdout, writing nothing" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt ALPHA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
  grep -q "^systemd-creds decrypt --user --name ALPHA $creds/ALPHA.cred$" "$calls"
  # only the record exists — decrypt wrote no plaintext beside it
  [ "$(find "$creds" -type f | wc -l)" = "1" ]
}

# One decrypt per record, not one per field: the record's plaintext json comes back whole and jq
# picks the field the caller asked for, so a record with several fields costs one sops process.
@test "decrypt resolves the .sops.json backend and asks sopsctl for the whole record" {
  write_in 'cipher'
  run ctl encrypt BETA.sops.json <"$stubs/in"
  SOPS_JSON='{"secret":"the-secret","other":"ignored"}' run ctl decrypt BETA
  [ "$status" -eq 0 ]
  [ "$output" = "the-secret" ]
  grep -q "^sopsctl decrypt $creds/BETA.sops.json\$" "$calls"
  assert_no_out 'ignored'
}

@test "decrypt on a missing record says so and exits 2" {
  run ctl decrypt NOPE
  [ "$status" -eq 2 ]
  grep -qi "$creds" <<<"$output"
}

@test "decrypt refuses a record with more than one extension instead of guessing" {
  printf 'cipher' >"$creds/EPSILON.cred"
  printf 'cipher' >"$creds/EPSILON.sops.json"
  printf 'cipher' >"$creds/EPSILON.sops.yaml"
  run ctl decrypt EPSILON
  [ "$status" -eq 1 ]
  grep -qi 'more than one' <<<"$output"
}

# A suffix spelled on the name is an explicit request, not a guess, so it resolves even when both
# files exist — that is how the xilo wrapper asks for the fast backend for a key it has in both.
@test "decrypt with an explicit suffix picks that backend when both records exist" {
  printf 'slow' >"$creds/EPSILON.cred"
  printf 'cipher' >"$creds/EPSILON.sops.json"
  SOPS_JSON='{"secret":"fast"}' run ctl decrypt EPSILON.sops.json
  [ "$status" -eq 0 ]
  [ "$output" = "fast" ]
  grep -q "^sopsctl decrypt $creds/EPSILON.sops.json\$" "$calls"
  run ! grep -q '^systemd-creds decrypt' "$calls"
}

# .sops.yaml names the same backend as .sops.json; which file wins is the suffix's choice, not a guess.
@test "decrypt with a .sops.yaml suffix picks the yaml record over the .cred and the .sops.json" {
  printf 'slow' >"$creds/EPSILON.cred"
  printf 'cipher' >"$creds/EPSILON.sops.json"
  printf 'cipher' >"$creds/EPSILON.sops.yaml"
  SOPS_JSON='{"secret":"yaml"}' run ctl decrypt EPSILON.sops.yaml
  [ "$status" -eq 0 ]
  [ "$output" = "yaml" ]
  grep -q "^sopsctl decrypt $creds/EPSILON.sops.yaml\$" "$calls"
  run ! grep -q '^systemd-creds decrypt' "$calls"
}

@test "a failed decrypt exits 3 and points at the credential backend" {
  write_in 'cipher'
  run ctl encrypt BETA.sops.json <"$stubs/in"
  SOPS_DECRYPT_EXIT=1 run ctl decrypt BETA
  [ "$status" -eq 3 ]
  grep -qi '.cred' <<<"$output"
}

@test "a failed credential decrypt exits 3, not a silent empty value" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  SC_DECRYPT_EXIT=1 run ctl decrypt ALPHA
  [ "$status" -eq 3 ]
  assert_no_out 'cipher'
}

# --- decrypt -- CMD ---------------------------------------------------------

@test "decrypt --env NAME -- CMD hands the secret to the command's environment" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- sh -c 'printf "%s\n" "$ALPHA"'
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
}

@test "decrypt --env several names -- CMD hands every secret and passes the command's own args through" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  run ctl decrypt --env ALPHA BETA -- sh -c 'printf "%s|%s|%s\n" "$ALPHA" "$BETA" "$1"' _ tail
  [ "$status" -eq 0 ]
  [ "$output" = "cipher|stub-plain|tail" ]
}

@test "--env hands the secret to a command that reads its own environment" {
  # The command must read the variable itself — credsctl cannot fill in a name the calling shell
  # already expanded to nothing.
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- printenv ALPHA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
}

# Typing `--env` before every name is the natural spelling; the flag is a marker, not a
# positional prefix, so a second one must not be read as a record name.
@test "decrypt accepts --env before any name, not only the first" {
  printf 'alice' >"$creds/ALPHA.cred"
  printf 'bob' >"$creds/BETA.cred"
  run ctl decrypt --env ALPHA --env BETA -- sh -c 'printf "%s|%s\n" "$ALPHA" "$BETA"'
  [ "$status" -eq 0 ]
  [ "$output" = "alice|bob" ]
  run ctl decrypt --env ALPHA --env BETA
  [ "$output" = "ALPHA=alice
BETA=bob" ]
}

@test "--env rejects a name the shell cannot expand instead of exporting a dead variable" {
  printf 'cipher' >"$creds/MY.TOKEN.cred"
  run ctl decrypt --env MY.TOKEN -- sh -c 'printf "%s\n" "$MY.TOKEN"'
  [ "$status" -eq 1 ]
  grep -q 'not a usable environment variable name' <<<"$output"
  # A path is not a name: --env resolves inside the store, so the message says which form to use.
  run ctl decrypt --env "$creds/MY.TOKEN.cred" -- sh -c 'printf "%s\n" "$MY.TOKEN"'
  [ "$status" -eq 1 ]
  grep -q 'bare credential name' <<<"$output"
  run ctl decrypt --env MY.TOKEN
  [ "$status" -eq 1 ]
  assert_no_out 'cipher'
}

# --- decrypt --env on a bundle record -----------------------------------------

# The fields are the variables, so one record fills an entire set. Assignments are read NUL-separated:
# split on newlines and a multi-line secret would arrive as two broken variables.
@test "decrypt --env on a bundle record exports every field from one decrypt" {
  bundle=$(jq -c -n --arg u 'https://xilo.test' --arg c 'acme/pkgs' --arg t $'tok\nmulti\nline' '{XILO_URL:$u,XILO_CACHE:$c,XILO_TOKEN:$t}')
  jq -n --arg u 'https://xilo.test' --arg c 'acme/pkgs' --arg t $'tok\nmulti\nline' '{XILO_URL:$u,XILO_CACHE:$c,XILO_TOKEN:$t}' >"$stubs/fields"
  run ctl encrypt XILO.sops.json --fields "$stubs/fields"
  [ "$status" -eq 0 ]
  # The payload goes into the environment of the run, which is how credsctl hands it to sopsctl.
  # An `export` inside a @test body is local to that subshell — SC2030/SC2031 — so never export here.
  SOPS_JSON="$bundle" run ctl decrypt --env XILO -- sh -c 'printf "[%s][%s][%s]\n" "$XILO_URL" "$XILO_TOKEN" "$XILO_CACHE"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '[https://xilo.test][tok\nmulti\nline][acme/pkgs]')" ]
  [ "$(grep -c '^sopsctl decrypt ' "$calls")" = "1" ]
}

# A record a person or another tool wrote may hold fields encrypt would never accept: a number, an
# empty value, a key no shell can name. Those are not secrets — they are skipped, never exported and
# never printed. `secret` is the record's own secret, so it takes the record's name.
@test "decrypt --env on a bundle record maps a secret field to the record name and skips what a shell cannot name" {
  printf 'cipher' >"$creds/PACK.sops.json"
  # Literal JSON for the stub, in the environment of each run: an `export` inside a @test body is
  # local to that subshell (SC2030/SC2031), and credsctl passes SOPS_JSON to sopsctl from the env.
  payload='{"secret":"alice","TOKEN":"bob","host.unencrypted":"leak","count":3,"empty":""}'
  SOPS_JSON="$payload" run ctl decrypt --env PACK
  [ "$status" -eq 0 ]
  [ "$output" = "PACK=alice
TOKEN=bob" ]
  SOPS_JSON="$payload" run ctl decrypt --env PACK -- sh -c 'printf "%s\n" "$(printenv host.unencrypted || echo unset)"'
  [ "$output" = "unset" ]
  assert_no_out 'leak'
}

# A yaml bundle is read through the same single decrypt, so the multi-line value survives the same
# NUL-separated assignment path.
@test "decrypt --env on a yaml bundle exports every field from one decrypt" {
  bundle=$(jq -c -n --arg u 'https://xilo.test' --arg t $'tok\nmulti\nline' '{XILO_URL:$u,XILO_TOKEN:$t}')
  jq -n --arg u 'https://xilo.test' --arg t $'tok\nmulti\nline' '{XILO_URL:$u,XILO_TOKEN:$t}' >"$stubs/fields"
  run ctl encrypt XILO.sops.yaml --fields "$stubs/fields"
  [ "$status" -eq 0 ]
  SOPS_JSON="$bundle" run ctl decrypt --env XILO -- sh -c 'printf "[%s][%s]\n" "$XILO_URL" "$XILO_TOKEN"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '[https://xilo.test][tok\nmulti\nline]')" ]
  [ "$(grep -c '^sopsctl decrypt ' "$calls")" = "1" ]
}

# Plain decrypt prints one secret and nothing else; a bundle has no single secret to print, so the
# message names the form that can read it rather than reporting a key problem that is not the cause.
@test "decrypt NAME on a bundle record with no secret field exits 2 and points at --env" {
  printf '{"XILO_TOKEN":"bob"}' >"$stubs/fields"
  run ctl encrypt XILO.sops.json --fields "$stubs/fields"
  SOPS_JSON='{"XILO_TOKEN":"bob"}' run ctl decrypt XILO
  [ "$status" -eq 2 ]
  grep -q -- '--env XILO' <<<"$output"
  assert_no_out 'bob'
  SOPS_JSON='{"secret":"alice","XILO_TOKEN":"bob"}' run ctl decrypt XILO
  [ "$output" = "alice" ]
}

@test "the command's exit status is credsctl's exit status" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- false
  [ "$status" -eq 1 ]
  run -127 ctl decrypt --env ALPHA -- no-such-binary
}

@test "with a command the secret is never printed to stdout" {
  write_in 'cipher'
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- true
  [ "$status" -eq 0 ]
  assert_no_out 'cipher'
}

@test "a command without --env is a usage error" {
  printf 'cipher' >"$creds/ALPHA.cred"
  run ctl decrypt ALPHA -- true
  [ "$status" -eq 1 ]
  grep -q 'a command needs --env' <<<"$output"
}

@test "a bare -- with no command is a usage error" {
  printf 'cipher' >"$creds/ALPHA.cred"
  run ctl decrypt --env ALPHA --
  [ "$status" -eq 1 ]
  grep -q 'nothing after --' <<<"$output"
}

@test "a missing record fails before the command runs" {
  printf 'cipher' >"$creds/ALPHA.cred"
  run ctl decrypt --env ALPHA GHOST -- sh -c 'printf "%s\n" "$ALPHA"'
  [ "$status" -eq 2 ]
  grep -q "no record named 'GHOST'" <<<"$output"
  assert_no_out 'cipher'
}

# --- usage ------------------------------------------------------------------

# writeShellApplication prefixes errexit/nounset/pipefail onto this file, so the artefact that
# ships runs under -e while `bash "$script"` does not. The shipped preamble must round-trip too.
@test "the packaged errexit preamble survives a full encrypt/list/decrypt/rm round-trip" {
  write_in 'secret'
  bash -euo pipefail "$script" encrypt ERREXIT <"$stubs/in"
  [ -e "$creds/ERREXIT.cred" ]
  bash -euo pipefail "$script" list
  [ "$(bash -euo pipefail "$script" decrypt ERREXIT)" = "secret" ]
  bash -euo pipefail "$script" rm ERREXIT
  [ ! -e "$creds/ERREXIT.cred" ]
}

@test "bare invocation prints the whole contract: commands, change recipe, backends, exit codes" {
  run ctl
  [ "$status" -eq 0 ]
  grep -q 'credsctl <list|encrypt|decrypt|rm>' <<<"$output"
  grep -q 'encrypt NAME' <<<"$output"
  grep -q 'encrypt NAME.sops.json' <<<"$output"
  grep -q 'decrypt NAME \[NAME...\]' <<<"$output"
  grep -q 'decrypt --env' <<<"$output"
  grep -q 'decrypt --env ... -- CMD' <<<"$output"
  grep -q 'printenv' <<<"$output"
  grep -q 'rm NAME \[NAME...\]' <<<"$output"
  grep -q 'records are immutable' <<<"$output"
  grep -q 'CREDS_DIR, CREDENTIALS_DIRECTORY, CREDS_ROOT' <<<"$output"
  grep -q 'sopsctl takes AGE_ROOT (where the age identity lives' <<<"$output"
  grep -q 'SOPS_RECIPIENTS (an optional recipient file whose keys join the rules)' <<<"$output"
  grep -q 'decrypt FILE' <<<"$output"
  grep -q '1 bad usage · 2 no such record · 3 encrypt or decrypt failed' <<<"$output"
  # The rule that matters is the one people get wrong: a portable record must still need no terminal.
  grep -q '\.cred = this machine, no prompt' <<<"$output"
  grep -qF '.sops.json and .sops.yaml = portable' <<<"$output"
  grep -q 'sopsctl' <<<"$output"
}

@test "usage reflects the overrides actually in effect" {
  CREDS_DIR="$stubs/other" run ctl help
  [ "$status" -eq 0 ]
  grep -q "$stubs/other" <<<"$output"
}

@test "an unknown command points at help rather than guessing" {
  run ctl rotate
  [ "$status" -eq 1 ]
  # bats folds stderr into $output unless run gets --separate-stderr.
  grep -q "unknown command 'rotate'" <<<"$output"
  grep -q "credsctl help" <<<"$output"
}

# --- real tier: the flags only the real binaries can reject ------------------

# A real sops store for the three real-tier tests below: the unstubbed sopsctl beside the host
# binaries, a mock age key, and the recipient file beside the records. A non-zero return means the
# host has no sops or age-keygen, so the caller skips. CREDS_ROOT keeps sopsctl's rules-file
# default inside the fixture, so the suite never reads ~/.local/share/credentials/.sops.yaml.
sops_store() {
  real="$stubs/$1"
  mkdir -p "$real" "$real/bin"
  cp "$repo/features/hm-creds/sopsctl.sh" "$real/bin/sopsctl"
  chmod +x "$real/bin/sopsctl"
  PATH="$host_path" command -v sops >/dev/null 2>&1 || return 1
  PATH="$host_path" age-keygen -o "$real/key" 2>/dev/null || return 1
  grep '^# public key:' "$real/key" | awk '{print $NF}' >"$real/recipient"
}
@test "real systemd-creds round-trips a record and rejects a renamed one" {
  PATH="$host_path" command -v systemd-creds >/dev/null 2>&1 || skip "systemd-creds not on host PATH"
  real="$stubs/real"
  mkdir -p "$real"
  PATH="$host_path" CREDS_DIR="$real" bash "$script" encrypt REAL <<<'hello world'
  [ -e "$real/REAL.cred" ]
  [ "$(stat -c '%a' "$real/REAL.cred")" = "400" ]
  out=$(PATH="$host_path" CREDS_DIR="$real" bash "$script" decrypt REAL)
  [ "$out" = "hello world" ]
  mv "$real/REAL.cred" "$real/OTHER.cred"
  PATH="$host_path" CREDS_DIR="$real" run bash "$script" decrypt OTHER
  [ "$status" -ne 0 ]
  # the name is embedded at encrypt time, so the renamed file must not decrypt as OTHER
  assert_no_out 'hello world'
}

# The delegation is only real if the real sopsctl runs against the real sops, so this puts the
# unstubbed sopsctl on PATH beside the host binaries.
@test "real sops round-trips a portable record through credsctl" {
  sops_store real-sops || skip "no sops or age-keygen on the host PATH"
  PATH="$real/bin:$host_path" CREDS_DIR="$real" CREDS_ROOT="$real" SOPS_RECIPIENTS="$real/recipient" \
    SOPS_AGE_FILE="$real/key" bash "$script" encrypt PORTABLE.sops.json <<<'hello sops'
  [ "$(stat -c '%a' "$real/PORTABLE.sops.json")" = "400" ]
  # encrypt names the backend with the suffix; decrypt resolves it from the file that exists.
  out=$(PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_AGE_FILE="$real/key" \
    bash "$script" decrypt PORTABLE)
  [ "$out" = "hello sops" ]
}

# The bundle shape, end to end with the real sops: several secrets and a multi-line one, read back
# as environment variables by one decrypt. Mock key, mock secrets — nothing here touches a real
# identity or record.
@test "real sops round-trips a bundle record and hands every field to a command" {
  sops_store real-bundle || skip "no sops or age-keygen on the host PATH"
  jq -n --arg u 'https://xilo.test' --arg t $'tok\nmulti\nline' '{XILO_URL:$u,XILO_TOKEN:$t}' >"$real/fields"
  PATH="$real/bin:$host_path" CREDS_DIR="$real" CREDS_ROOT="$real" SOPS_RECIPIENTS="$real/recipient" \
    SOPS_AGE_FILE="$real/key" run bash "$script" encrypt XILO.sops.json --fields "$real/fields"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$real/XILO.sops.json")" = "400" ]
  out=$(PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_AGE_FILE="$real/key" \
    bash "$script" decrypt --env XILO -- sh -c 'printf "[%s][%s]\n" "$XILO_URL" "$XILO_TOKEN"')
  [ "$out" = "$(printf '[https://xilo.test][tok\nmulti\nline]')" ]
  PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_AGE_FILE="$real/key" run bash "$script" decrypt XILO
  [ "$status" -eq 2 ]
}

# The same bundle in the yaml shape, end to end with real sops and a mock key. Security properties
# are asserted, not just the values: the record stays ciphertext and 0400, no plaintext file appears
# in the store, and nothing the secrets contain reaches stdout.
@test "real sops round-trips a yaml bundle record and hands every field to a command" {
  sops_store real-yaml-bundle || skip "no sops or age-keygen on the host PATH"
  jq -n --arg u 'https://xilo.test' --arg t $'tok\nmulti\nline' '{XILO_URL:$u,XILO_TOKEN:$t}' >"$real/fields"
  PATH="$real/bin:$host_path" CREDS_DIR="$real" CREDS_ROOT="$real" SOPS_RECIPIENTS="$real/recipient" \
    SOPS_AGE_FILE="$real/key" run bash "$script" encrypt XILO.sops.yaml --fields "$real/fields"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$real/XILO.sops.yaml")" = "400" ]
  grep -q '^XILO_TOKEN: ENC\[AES256_GCM,data:' "$real/XILO.sops.yaml"
  run ! grep -q 'xilo.test' "$real/XILO.sops.yaml"
  out=$(PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_AGE_FILE="$real/key" \
    bash "$script" decrypt --env XILO -- sh -c 'printf "[%s][%s]\n" "$XILO_URL" "$XILO_TOKEN"')
  [ "$out" = "$(printf '[https://xilo.test][tok\nmulti\nline]')" ]
  # Nothing decrypted lands in the store, and the plain decrypt prints only the record's own secret.
  # LC_ALL=C so the record sorts first; the host's UTF-8 collation folds case and would not.
  [ "$(find "$real" -type f -not -path "$real/bin/*" | LC_ALL=C sort | tr '\n' ' ')" = "$real/XILO.sops.yaml $real/fields $real/key $real/recipient " ]
  PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_AGE_FILE="$real/key" run bash "$script" decrypt XILO.sops.yaml
  [ "$status" -eq 2 ]
}
