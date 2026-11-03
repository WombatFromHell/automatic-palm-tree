#!/usr/bin/env bash
# The `sh -c '...'` snippets in this file must reach sh unexpanded: $ALPHA is sh's variable, not
# this test's, so the single quotes are deliberate.
# shellcheck disable=SC2016
# features/hm-creds/credsctl.sh against PATH stubs plus one real round-trip per backend.
#
# Contract under test: a record is one file holding one secret in $CREDS_DIR; the extension picks
# the backend (<name>.cred = systemd-creds, <name>.sops.json = sops through sopsctl); records are
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

bats_require_minimum_version 1.5.0

setup() {
  repo="$PWD"
  script="$repo/features/hm-creds/credsctl.sh"
  host_path="$PATH"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : >"$calls"
  creds="$stubs/creds"
  mkdir -p "$creds"

  cat >"$stubs/systemd-creds" <<EOF
#!/usr/bin/env bash
echo "systemd-creds \$*" >> "$calls"
case "\$1" in
  encrypt)
    [ "\$2" = "--user" ] && [ "\$3" = "--name" ] || exit 9
    [ "\${SC_ENCRYPT_EXIT:-0}" = 0 ] || exit "\$SC_ENCRYPT_EXIT"
    cat > "\${@: -1}" ;;
  decrypt)
    [ "\$2" = "--user" ] && [ "\$3" = "--name" ] || exit 9
    if [ "\${SC_DECRYPT_EXIT:-0}" != 0 ]; then echo "stub: cannot decrypt" >&2; exit "\$SC_DECRYPT_EXIT"; fi
    cat "\${@: -1}" ;;
  list)
    [ "\$2" = "--user" ] || exit 9
    [ "\${SC_LIST_EXIT:-0}" = 0 ] || exit "\$SC_LIST_EXIT"
    if [ -n "\${SC_LIST_OUT:-}" ]; then printf '%s\n' "\${SC_LIST_OUT}"; fi ;;
  *) exit 9 ;;
esac
EOF
  # The portable backend is a delegation: sopsctl owns the sops flags, the recipients and the key
  # command, so this stub only has to behave like a record store — encrypt reads json on stdin and
  # writes ciphertext on stdout, get prints one field.
  cat >"$stubs/sopsctl" <<EOF
#!/usr/bin/env bash
echo "sopsctl \$*" >> "$calls"
case "\$1" in
  encrypt)
    [ "\${SOPS_ENCRYPT_EXIT:-0}" = 0 ] || exit "\${SOPS_ENCRYPT_EXIT}"
    cat ;;
  get)
    [ "\$2" = secret ] || exit 9
    [ "\${SOPS_GET_EXIT:-0}" = 0 ] || { echo "sopsctl: cannot decrypt \$3" >&2; exit "\${SOPS_GET_EXIT}"; }
    printf '%s' "\${SOPS_PLAIN:-stub-plain}" ;;
  *) exit 9 ;;
esac
EOF
  chmod +x "$stubs/systemd-creds" "$stubs/sopsctl"
  export CREDS_DIR="$creds"
  PATH="$stubs:$PATH"
}

teardown() { rm -rf "$stubs"; }

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
    run env HOME="$stubs/home" PATH="$stubs/bin:$PATH" CREDS_DIR="$store" bash "$script" list
  [ "$status" -eq 0 ]
  grep -q 'alpha.cred secure' <<<"$output"
  grep -q 'beta.sops.json' <<<"$output"
  grep -q '^systemd-creds list --user' "$calls"
  [ "$(grep -c 'alpha.cred' <<<"$output")" = 1 ]
}

@test "list on an overridden CREDS_DIR lists that directory and asks systemd for nothing" {
  printf 'cipher' >"$creds/alpha.cred"
  printf 'cipher' >"$creds/beta.sops.json"
  run ctl list
  [ "$status" -eq 0 ]
  grep -q 'alpha.cred .* insecure' <<<"$output"
  grep -q 'beta.sops.json .* insecure' <<<"$output"
  [ "$(grep -c 'systemd-creds list' "$calls")" = 0 ]
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
  run ! grep -q 'other.sops.json' <<<"$output"
  run env CREDS_DIR="$stubs/other" CREDENTIALS_DIRECTORY="$stubs/sys" bash "$script" list
  grep -q 'other.sops.json' <<<"$output"
  run ! grep -q 'token.sops.json' <<<"$output"
}

# --- encrypt ----------------------------------------------------------------

@test "encrypt writes a .cred record and passes --user --name, not a derived name" {
  printf 'secret' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  [ "$status" -eq 0 ]
  grep -q "^systemd-creds encrypt --user --name ALPHA - $creds/ALPHA.cred$" "$calls"
  [ "$(stat -c '%a' "$creds/ALPHA.cred")" = "400" ]
}

# The secret reaches sopsctl as a json field, because a sops record is a map and sops encrypts every
# value in it; credsctl keeps the one-secret-per-record contract by writing exactly one field.
@test "encrypt NAME.sops.json delegates to sopsctl and stores the secret as a json field" {
  printf 'secret' >"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  [ "$status" -eq 0 ]
  grep -q '^sopsctl encrypt$' "$calls"
  [ "$(cat "$creds/BETA.sops.json")" = '{"secret":"secret"}' ]
  [ "$(stat -c '%a' "$creds/BETA.sops.json")" = "400" ]
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
  printf 'secret' >"$stubs/in"
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
  printf 'secret' >"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  [ ! -e "$creds/BETA.sops.json.sops.json" ]
  run ctl decrypt BETA.sops.json
  [ "$output" = "stub-plain" ]
  grep -q '^sopsctl get secret ' "$calls"
}

@test "encrypt a failing backend exits 3 and leaves no record" {
  printf 'secret' >"$stubs/in"
  SC_ENCRYPT_EXIT=1 run ctl encrypt ALPHA <"$stubs/in"
  [ "$status" -eq 3 ]
  [ ! -e "$creds/ALPHA.cred" ]
  SOPS_ENCRYPT_EXIT=1 run ctl encrypt BETA.sops.json <"$stubs/in"
  [ "$status" -eq 3 ]
  [ ! -e "$creds/BETA.sops.json" ]
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
  run ! grep -q 'hunter2' <<<"$output"
  [ -e "$creds/TTYED.cred" ]
  run ctl decrypt TTYED
  [ "$output" = "hunter2" ]
}

# The delegate's failure must not leave an empty record behind: the redirect creates the file
# before the delegate runs, so a failed encrypt has to remove it. The delegate is stubbed to fail
# here rather than assumed absent — a deployed generation puts a working sopsctl on PATH.
@test "encrypt on a backend that cannot run fails and leaves no record behind" {
  printf 'secret' >"$stubs/in"
  printf '#!/usr/bin/env bash\necho "delegate boom" >&2\nexit 9\n' >"$stubs/sopsctl"
  chmod +x "$stubs/sopsctl"
  run env CREDS_DIR="$creds" bash "$script" encrypt DELTA.sops.json <"$stubs/in"
  [ "$status" -eq 3 ]
  [ ! -e "$creds/DELTA.sops.json" ]
}

# --- decrypt ----------------------------------------------------------------

@test "decrypt takes several names and prints one record per line" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  run ctl decrypt ALPHA BETA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher
stub-plain" ]
}

@test "decrypt --env prints KEY=VALUE with the credential name as the key" {
  printf 'cipher' >"$stubs/in"
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

@test "rm refuses a name that resolves to two records" {
  printf 'cipher' >"$creds/EPSILON.cred"
  printf 'cipher' >"$creds/EPSILON.sops.json"
  run ctl rm EPSILON
  [ "$status" -eq 1 ]
  grep -q 'both EPSILON.cred and EPSILON.sops.json exist' <<<"$output"
  [ -e "$creds/EPSILON.cred" ]
}

@test "rm with no name is a usage error" {
  run ctl rm
  [ "$status" -eq 1 ]
  grep -q 'rm needs at least one credential name' <<<"$output"
}

@test "decrypt resolves the .cred backend and prints to stdout, writing nothing" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt ALPHA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
  grep -q "^systemd-creds decrypt --user --name ALPHA $creds/ALPHA.cred$" "$calls"
  # only the record exists — decrypt wrote no plaintext beside it
  [ "$(find "$creds" -type f | wc -l)" = "1" ]
}

@test "decrypt resolves the .sops.json backend and asks sopsctl for the secret field" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  SOPS_PLAIN='the-secret' run ctl decrypt BETA
  [ "$status" -eq 0 ]
  [ "$output" = "the-secret" ]
  grep -q "^sopsctl get secret $creds/BETA.sops.json$" "$calls"
}

@test "decrypt on a missing record says so and exits 2" {
  run ctl decrypt NOPE
  [ "$status" -eq 2 ]
  grep -qi "$creds" <<<"$output"
}

@test "decrypt refuses a record with both extensions instead of guessing" {
  printf 'cipher' >"$creds/EPSILON.cred"
  printf 'cipher' >"$creds/EPSILON.sops.json"
  run ctl decrypt EPSILON
  [ "$status" -eq 1 ]
  grep -qi 'both' <<<"$output"
}

@test "a failed decrypt exits 3 and points at the credential backend" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  SOPS_GET_EXIT=1 run ctl decrypt BETA
  [ "$status" -eq 3 ]
  grep -qi '.cred' <<<"$output"
}

@test "a failed credential decrypt exits 3, not a silent empty value" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  SC_DECRYPT_EXIT=1 run ctl decrypt ALPHA
  [ "$status" -eq 3 ]
  run ! grep -q 'cipher' <<<"$output"
}

# --- decrypt -- CMD ---------------------------------------------------------

@test "decrypt --env NAME -- CMD hands the secret to the command's environment" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- sh -c 'printf "%s\n" "$ALPHA"'
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
}

@test "decrypt --env several names -- CMD hands every secret and passes the command's own args through" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl encrypt BETA.sops.json <"$stubs/in"
  run ctl decrypt --env ALPHA BETA -- sh -c 'printf "%s|%s|%s\n" "$ALPHA" "$BETA" "$1"' _ tail
  [ "$status" -eq 0 ]
  [ "$output" = "cipher|stub-plain|tail" ]
}

@test "--env hands the secret to a command that reads its own environment" {
  # The command must read the variable itself — credsctl cannot fill in a name the calling shell
  # already expanded to nothing.
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- printenv ALPHA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
  run ctl decrypt --env ALPHA -- sh -c 'printf "%s\n" "$ALPHA"'
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
  run ctl decrypt --env MY.TOKEN
  [ "$status" -eq 1 ]
  run ! grep -q 'cipher' <<<"$output"
}

@test "the command's exit status is credsctl's exit status" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- false
  [ "$status" -eq 1 ]
  run -127 ctl decrypt --env ALPHA -- no-such-binary
}

@test "with a command the secret is never printed to stdout" {
  printf 'cipher' >"$stubs/in"
  run ctl encrypt ALPHA <"$stubs/in"
  run ctl decrypt --env ALPHA -- true
  [ "$status" -eq 0 ]
  run ! grep -q 'cipher' <<<"$output"
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
  run ! grep -q 'cipher' <<<"$output"
}

# --- usage ------------------------------------------------------------------

# writeShellApplication prefixes errexit/nounset/pipefail onto this file, so the artefact that
# ships runs under -e while `bash "$script"` does not. The shipped preamble must round-trip too.
@test "the packaged errexit preamble survives a full encrypt/list/decrypt/rm round-trip" {
  printf 'secret' >"$stubs/in"
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
  grep -q 'CREDS_DIR, CREDENTIALS_DIRECTORY' <<<"$output"
  grep -q 'sopsctl takes SOPS_AGE_FILE (the identity file), SOPS_RULES (creation rules for new records), SOPS_KEYS_CMD (a wallet key), SOPS_RECIPIENTS (who can read a record)' <<<"$output"
  grep -q 'decrypt FILE' <<<"$output"
  grep -q '1 bad usage · 2 no such record · 3 encrypt or decrypt failed' <<<"$output"
}

# The rule that matters is the one people get wrong: a portable record must still need no terminal.
@test "usage names the backend rule so a portable record is fine for a unit" {
  run ctl help
  [ "$status" -eq 0 ]
  grep -q '\.cred = this machine, no prompt' <<<"$output"
  grep -q '\.sops.json = portable' <<<"$output"
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
  run ! grep -q 'hello world' <<<"$output"
}

# The delegation is only real if the real sopsctl runs against the real sops, so this puts the
# unstubbed sopsctl on PATH beside the host binaries.
@test "real sops round-trips a portable record through credsctl" {
  PATH="$host_path" command -v sops >/dev/null 2>&1 || skip "no sops on the host PATH"
  PATH="$host_path" command -v age-keygen >/dev/null 2>&1 || skip "no age-keygen on the host PATH"
  real="$stubs/real-sops"
  mkdir -p "$real" "$real/bin"
  cp "$repo/features/hm-creds/sopsctl.sh" "$real/bin/sopsctl"
  chmod +x "$real/bin/sopsctl"
  PATH="$host_path" age-keygen -o "$real/key" 2>/dev/null || skip "age-keygen failed"
  grep '^# public key:' "$real/key" | awk '{print $NF}' >"$real/recipient"
  PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_RECIPIENTS="$real/recipient" \
    SOPS_AGE_FILE="$real/key" bash "$script" encrypt PORTABLE.sops.json <<<'hello sops'
  [ "$(stat -c '%a' "$real/PORTABLE.sops.json")" = "400" ]
  # encrypt names the backend with the suffix; decrypt resolves it from the file that exists.
  out=$(PATH="$real/bin:$host_path" CREDS_DIR="$real" SOPS_AGE_FILE="$real/key" \
    bash "$script" decrypt PORTABLE)
  [ "$out" = "hello sops" ]
}
