#!/usr/bin/env bash
# features/hm-creds/credsctl.sh against PATH stubs plus one real round-trip per backend.
#
# Contract under test: a record is one file holding one secret in $CREDS_DIR; the extension picks
# the backend (<name>.cred = systemd-creds, <name>.age = age); records are immutable, so encrypt
# never overwrites and always writes 0400 — a change is remove + re-add; plaintext only ever goes
# to stdout. Exit codes: 1 usage, 2 no such record, 3 decrypt failed.
#
# Stubs record argv so the flags systemd-creds/age actually receive are asserted, not grepped for.
# The real-tier tests run on the host PATH with the stub dir removed; they skip when the real
# binaries are absent.

bats_require_minimum_version 1.5.0

setup() {
  repo="$PWD"
  script="$repo/features/hm-creds/credsctl.sh"
  host_path="$PATH"
  stubs="$(mktemp -d)"
  calls="$stubs/calls"
  : > "$calls"
  creds="$stubs/creds"
  mkdir -p "$creds"
  printf 'ssh-ed25519 AAAAtest test@example\n' > "$creds/recipient"
  printf 'ssh-ed25519 AAAATEST id\n' > "$stubs/id"

  cat > "$stubs/systemd-creds" <<EOF
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
  cat > "$stubs/age" <<EOF
#!/usr/bin/env bash
echo "age \$*" >> "$calls"
out=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  prev="\$a"
done
if [ "\$1" = "-d" ]; then
  if [ "\${AGE_DECRYPT_EXIT:-0}" != 0 ]; then
    echo "age: error: failed to obtain passphrase: standard input is not a terminal" >&2
    exit "\$AGE_DECRYPT_EXIT"
  fi
  printf '%s' "\${AGE_PLAIN:-stub-plain}"
  exit 0
fi
if [ "\$1" = "-r" ]; then
  [ "\${AGE_ENCRYPT_EXIT:-0}" = 0 ] || exit "\$AGE_ENCRYPT_EXIT"
  cat > "\$out"
  exit 0
fi
exit 9
EOF
  chmod +x "$stubs/systemd-creds" "$stubs/age"
  export CREDS_DIR="$creds"
  export CREDS_IDENTITY="$stubs/id"
  export CREDS_RECIPIENTS="$creds/recipient"
  PATH="$stubs:$PATH"
}

teardown() { rm -rf "$stubs"; }

ctl() { bash "$script" "$@"; }

# --- list -------------------------------------------------------------------

@test "list shows both backends, systemd's own lines plus the age records" {
  printf 'cipher' > "$creds/alpha.cred"
  printf 'cipher' > "$creds/beta.age"
  SC_LIST_OUT="alpha.cred insecure 6B $creds/alpha.cred" run ctl list
  [ "$status" -eq 0 ]
  grep -q 'alpha.cred insecure' <<< "$output"
  grep -q 'beta.age' <<< "$output"
  grep -q '^systemd-creds list --user' "$calls"
}

@test "list on an empty store exits 0 and names nothing" {
  run ctl list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- encrypt ----------------------------------------------------------------

@test "encrypt writes a .cred record and passes --user --name, not a derived name" {
  printf 'secret' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  [ "$status" -eq 0 ]
  grep -q "^systemd-creds encrypt --user --name ALPHA - $creds/ALPHA.cred$" "$calls"
  [ "$(stat -c '%a' "$creds/ALPHA.cred")" = "400" ]
}

@test "encrypt NAME.age goes through age with the recipient file" {
  printf 'secret' > "$stubs/in"
  run ctl encrypt BETA.age < "$stubs/in"
  [ "$status" -eq 0 ]
  grep -q '^age -r ssh-ed25519 AAAAtest test@example -o ' "$calls"
  [ "$(stat -c '%a' "$creds/BETA.age")" = "400" ]
}

@test "encrypt never overwrites: a record is removed and re-added to change it" {
  printf 'one' > "$stubs/one"
  printf 'two' > "$stubs/two"
  run ctl encrypt ALPHA < "$stubs/one"
  run ctl encrypt ALPHA < "$stubs/two"
  [ "$status" -eq 1 ]
  grep -qi 'remove' <<< "$output"
  [ "$(cat "$creds/ALPHA.cred")" = "one" ]
  [ "$(grep -c '^systemd-creds encrypt' "$calls")" = "1" ]
}

@test "encrypt takes a file argument as well as stdin" {
  printf 'from-file' > "$stubs/src"
  run ctl encrypt GAMMA "$stubs/src"
  [ "$status" -eq 0 ]
  [ "$(cat "$creds/GAMMA.cred")" = "from-file" ]
}

@test "encrypt takes one credential at a time" {
  run ctl encrypt ALPHA BETA EXTRA
  [ "$status" -eq 1 ]
  grep -q 'one credential at a time' <<< "$output"
  [ ! -e "$creds/ALPHA.cred" ]
}

@test "encrypt refuses an empty secret and a name that is not a credential ID" {
  : > "$stubs/empty"
  run ctl encrypt EMPTY < "$stubs/empty"
  [ "$status" -eq 1 ]
  run ctl encrypt 'bad/name'
  [ "$status" -eq 1 ]
  run ctl encrypt '.hidden'
  [ "$status" -eq 1 ]
  [ ! -e "$creds/EMPTY.cred" ]
}

@test "encrypt on a terminal prompts for the secret and never echoes it back" {
  # The prompt branch is `[[ -t 0 ]]`, so this needs a real pty: type a secret, read what the
  # terminal shows, and check the record holds it. Echo is off, so the typed text must not appear.
  command -v python3 > /dev/null 2>&1 || skip "python3 not available"
  run python3 - "$script" "$creds" <<'PY'
import os, pty, sys
script, creds = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["CREDS_DIR"] = creds
    os.execv("/usr/bin/bash", ["bash", script, "encrypt", "TTYED"])
os.write(fd, b"hunter2\n")
chunks = []
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
  grep -q 'pty exit=0' <<< "$output"
  grep -q 'secret for TTYED:' <<< "$output"
  ! grep -q 'hunter2' <<< "$output"
  [ -e "$creds/TTYED.cred" ]
  run ctl decrypt TTYED
  [ "$output" = "hunter2" ]
}

@test "encrypt on a missing recipient file fails before writing anything" {
  rm "$creds/recipient"
  printf 'secret' > "$stubs/in"
  run ctl encrypt DELTA.age < "$stubs/in"
  [ "$status" -eq 1 ]
  [ ! -e "$creds/DELTA.age" ]
}

# --- decrypt ----------------------------------------------------------------

@test "decrypt takes several names and prints one record per line" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl encrypt BETA.age < "$stubs/in"
  run ctl decrypt ALPHA BETA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher
stub-plain" ]
}

@test "decrypt --env prints KEY=VALUE with the credential name as the key" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl encrypt BETA.age < "$stubs/in"
  run ctl decrypt --env ALPHA BETA
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA=cipher
BETA=stub-plain" ]
}

@test "decrypt with no name is a usage error" {
  run ctl decrypt
  [ "$status" -eq 1 ]
  grep -q 'decrypt needs at least one credential name' <<< "$output"
}

# --- rm ---------------------------------------------------------------------

@test "rm removes several credentials in one call and touches no backend" {
  printf 'cipher' > "$creds/ALPHA.cred"
  printf 'cipher' > "$creds/BETA.age"
  printf 'cipher' > "$creds/GAMMA.cred"
  run ctl rm ALPHA BETA GAMMA
  [ "$status" -eq 0 ]
  [ ! -e "$creds/ALPHA.cred" ]
  [ ! -e "$creds/BETA.age" ]
  [ ! -e "$creds/GAMMA.cred" ]
  [ ! -s "$calls" ]
}

@test "rm with a name that has no record removes nothing at all and exits 2" {
  printf 'cipher' > "$creds/ALPHA.cred"
  printf 'cipher' > "$creds/BETA.cred"
  run ctl rm ALPHA GHOST
  [ "$status" -eq 2 ]
  [ -e "$creds/ALPHA.cred" ]
  [ -e "$creds/BETA.cred" ]
}

@test "rm on a repeated name deletes the record once and succeeds" {
  printf 'cipher' > "$creds/ALPHA.cred"
  run ctl rm ALPHA ALPHA
  [ "$status" -eq 0 ]
  [ ! -e "$creds/ALPHA.cred" ]
}

@test "rm refuses a name that resolves to two records" {
  printf 'cipher' > "$creds/EPSILON.cred"
  printf 'cipher' > "$creds/EPSILON.age"
  run ctl rm EPSILON
  [ "$status" -eq 1 ]
  grep -q 'both EPSILON.cred and EPSILON.age exist' <<< "$output"
  [ -e "$creds/EPSILON.cred" ]
}

@test "rm with no name is a usage error" {
  run ctl rm
  [ "$status" -eq 1 ]
  grep -q 'rm needs at least one credential name' <<< "$output"
}

@test "decrypt resolves the .cred backend and prints to stdout, writing nothing" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl decrypt ALPHA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
  grep -q "^systemd-creds decrypt --user --name ALPHA $creds/ALPHA.cred$" "$calls"
  # only the record and the recipient file exist — decrypt wrote no plaintext next to them
  [ "$(find "$creds" -type f | wc -l)" = "2" ]
}

@test "decrypt resolves the .age backend and passes the identity path" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt BETA.age < "$stubs/in"
  AGE_PLAIN='the-secret' run ctl decrypt BETA
  [ "$status" -eq 0 ]
  [ "$output" = "the-secret" ]
  grep -q "^age -d -i $stubs/id $creds/BETA.age$" "$calls"
}

@test "decrypt on a missing record says so and exits 2" {
  run ctl decrypt NOPE
  [ "$status" -eq 2 ]
  grep -qi "$creds" <<< "$output"
}

@test "decrypt refuses a record with both extensions instead of guessing" {
  printf 'cipher' > "$creds/EPSILON.cred"
  printf 'cipher' > "$creds/EPSILON.age"
  run ctl decrypt EPSILON
  [ "$status" -eq 1 ]
  grep -qi 'both' <<< "$output"
}

@test "a failed decrypt exits 3 and points at the credential backend" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt BETA.age < "$stubs/in"
  AGE_DECRYPT_EXIT=1 run ctl decrypt BETA
  [ "$status" -eq 3 ]
  grep -qi '.cred' <<< "$output"
}

@test "a failed credential decrypt exits 3, not a silent empty value" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  SC_DECRYPT_EXIT=1 run ctl decrypt ALPHA
  [ "$status" -eq 3 ]
  ! grep -q 'cipher' <<< "$output"
}

# --- decrypt -- CMD ---------------------------------------------------------

@test "decrypt --env NAME -- CMD hands the secret to the command's environment" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl decrypt --env ALPHA -- sh -c 'printf "%s\n" "$ALPHA"'
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
}

@test "decrypt --env several names -- CMD hands every secret and passes the command's own args through" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl encrypt BETA.age < "$stubs/in"
  run ctl decrypt --env ALPHA BETA -- sh -c 'printf "%s|%s|%s\n" "$ALPHA" "$BETA" "$1"' _ tail
  [ "$status" -eq 0 ]
  [ "$output" = "cipher|stub-plain|tail" ]
}

@test "--env hands the secret to a command that reads its own environment" {
  # The command must read the variable itself — credsctl cannot fill in a name the calling shell
  # already expanded to nothing.
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl decrypt --env ALPHA -- printenv ALPHA
  [ "$status" -eq 0 ]
  [ "$output" = "cipher" ]
  run ctl decrypt --env ALPHA -- sh -c 'printf "%s\n" "$ALPHA"'
  [ "$output" = "cipher" ]
}

# Typing `--env` before every name is the natural spelling; the flag is a marker, not a
# positional prefix, so a second one must not be read as a record name.
@test "decrypt accepts --env before any name, not only the first" {
  printf 'alice' > "$creds/ALPHA.cred"
  printf 'bob' > "$creds/BETA.cred"
  run ctl decrypt --env ALPHA --env BETA -- printenv ALPHA BETA
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA=alice
BETA=bob" ]
}

@test "--env rejects a name the shell cannot expand instead of exporting a dead variable" {
  printf 'cipher' > "$creds/MY.TOKEN.cred"
  run ctl decrypt --env MY.TOKEN -- sh -c 'printf "%s\n" "$MY.TOKEN"'
  [ "$status" -eq 1 ]
  grep -q 'not a usable environment variable name' <<< "$output"
  run ctl decrypt --env MY.TOKEN
  [ "$status" -eq 1 ]
  ! grep -q 'cipher' <<< "$output"
}

@test "the command's exit status is credsctl's exit status" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl decrypt --env ALPHA -- false
  [ "$status" -eq 1 ]
  run -127 ctl decrypt --env ALPHA -- no-such-binary
}

@test "with a command the secret is never printed to stdout" {
  printf 'cipher' > "$stubs/in"
  run ctl encrypt ALPHA < "$stubs/in"
  run ctl decrypt --env ALPHA -- true
  [ "$status" -eq 0 ]
  ! grep -q 'cipher' <<< "$output"
}

@test "a command without --env is a usage error" {
  printf 'cipher' > "$creds/ALPHA.cred"
  run ctl decrypt ALPHA -- true
  [ "$status" -eq 1 ]
  grep -q 'a command needs --env' <<< "$output"
}

@test "a bare -- with no command is a usage error" {
  printf 'cipher' > "$creds/ALPHA.cred"
  run ctl decrypt --env ALPHA --
  [ "$status" -eq 1 ]
  grep -q 'nothing after --' <<< "$output"
}

@test "a missing record fails before the command runs" {
  printf 'cipher' > "$creds/ALPHA.cred"
  run ctl decrypt --env ALPHA GHOST -- sh -c 'printf "%s\n" "$ALPHA"'
  [ "$status" -eq 2 ]
  grep -q "no record named 'GHOST'" <<< "$output"
  ! grep -q 'cipher' <<< "$output"
}

# --- usage ------------------------------------------------------------------

@test "bare invocation prints the whole contract: commands, change recipe, backends, exit codes" {
  run ctl
  [ "$status" -eq 0 ]
  grep -q 'credsctl <list|encrypt|decrypt|rm>' <<< "$output"
  grep -q 'encrypt NAME' <<< "$output"
  grep -q 'encrypt NAME.age' <<< "$output"
  grep -q 'decrypt NAME \[NAME...\]' <<< "$output"
  grep -q 'decrypt --env' <<< "$output"
  grep -q 'decrypt --env ... -- CMD' <<< "$output"
  grep -q 'printenv' <<< "$output"
  grep -q 'rm NAME \[NAME...\]' <<< "$output"
  grep -q 'records are immutable' <<< "$output"
  grep -q 'CREDS_DIR, CREDS_IDENTITY, CREDS_RECIPIENTS' <<< "$output"
  grep -q '1 bad usage · 2 no such record · 3 decrypt failed' <<< "$output"
}

@test "usage names the backend rule so a .age record is not chosen for a unit" {
  run ctl help
  [ "$status" -eq 0 ]
  grep -q '\.cred = this machine, no prompt' <<< "$output"
  grep -q '\.age = portable' <<< "$output"
  grep -q "$stubs/id" <<< "$output"
}

@test "usage reflects the overrides actually in effect" {
  CREDS_IDENTITY="$stubs/id" CREDS_RECIPIENTS="$creds/other" run ctl help
  [ "$status" -eq 0 ]
  grep -q "$stubs/id" <<< "$output"
  grep -q "$creds/other" <<< "$output"
}

@test "an unknown command points at help rather than guessing" {
  run ctl rotate
  [ "$status" -eq 1 ]
  # bats folds stderr into $output unless run gets --separate-stderr.
  grep -q "unknown command 'rotate'" <<< "$output"
  grep -q "credsctl help" <<< "$output"
}

# --- real tier: the flags only the real binaries can reject ------------------

@test "real systemd-creds round-trips a record and rejects a renamed one" {
  PATH="$host_path" command -v systemd-creds > /dev/null 2>&1 || skip "systemd-creds not on host PATH"
  real="$stubs/real"
  mkdir -p "$real"
  PATH="$host_path" CREDS_DIR="$real" bash "$script" encrypt REAL <<< 'hello world'
  [ -e "$real/REAL.cred" ]
  [ "$(stat -c '%a' "$real/REAL.cred")" = "400" ]
  out=$(PATH="$host_path" CREDS_DIR="$real" bash "$script" decrypt REAL)
  [ "$out" = "hello world" ]
  mv "$real/REAL.cred" "$real/OTHER.cred"
  PATH="$host_path" CREDS_DIR="$real" run bash "$script" decrypt OTHER
  [ "$status" -ne 0 ]
  # the name is embedded at encrypt time, so the renamed file must not decrypt as OTHER
  ! grep -q 'hello world' <<< "$output"
}

@test "real age round-trips a record with its recipient" {
  PATH="$host_path" command -v age > /dev/null 2>&1 || skip "age not on host PATH"
  PATH="$host_path" command -v age-keygen > /dev/null 2>&1 || skip "age-keygen not on host PATH"
  real="$stubs/real-age"
  mkdir -p "$real"
  # The stub dir is on PATH here; keygen must be the real one or the identity is a stub no-op.
  PATH="$host_path" age-keygen -o "$real/id" > /dev/null 2>&1
  PATH="$host_path" age-keygen -y "$real/id" > "$real/recipient"
  PATH="$host_path" CREDS_DIR="$real" CREDS_IDENTITY="$real/id" CREDS_RECIPIENTS="$real/recipient" \
    bash "$script" encrypt PORTABLE.age <<< 'hello age'
  [ "$(stat -c '%a' "$real/PORTABLE.age")" = "400" ]
  # encrypt names the backend with the suffix; decrypt resolves it from the file that exists.
  out=$(PATH="$host_path" CREDS_DIR="$real" CREDS_IDENTITY="$real/id" CREDS_RECIPIENTS="$real/recipient" \
    bash "$script" decrypt PORTABLE)
  [ "$out" = "hello age" ]
}
