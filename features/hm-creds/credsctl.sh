#!/usr/bin/env bash
# credsctl — one record store, two backends.
#
# A record is one file holding exactly one secret, in $CREDS_DIR (default
# ~/.local/share/credentials). The extension picks the backend:
#   <name>.cred  systemd-creds: decrypted silently, and bound to this machine (UID + machine-id),
#                so it cannot be carried to another host.
#   <name>.age   age with $CREDS_IDENTITY: portable across hosts, but age reads the identity
#                passphrase from a terminal only (no ssh-agent, no SSH_ASKPASS), so a systemd unit
#                or an elevated push cannot unlock it. Machine-local automation records stay .cred.
#
# Records are immutable: encrypt never overwrites and every record is written 0400, so changing a
# secret means `rm <name>.<ext>` and encrypting again. Plaintext only ever goes to stdout.
set -uo pipefail

# The store: CREDS_DIR for a record store you point somewhere else, CREDENTIALS_DIRECTORY (what
# systemd sets for generated credentials) as the real location, and systemd's own store as the
# default. One chain here, so every caller -- xilo-wrapped, njust's _push -- reads the same store.
creds_dir="${CREDS_DIR:-${CREDENTIALS_DIRECTORY:-$HOME/.local/share/credentials}}"
identity="${CREDS_IDENTITY:-$HOME/.ssh/flakeroot_ed25519}"
recipients="${CREDS_RECIPIENTS:-$creds_dir/recipient}"

die() {
  echo "credsctl: $1" >&2
  exit "${2:-1}"
}

# A record name doubles as a systemd credential ID, and systemd-creds compares the name embedded
# at encrypt time against the one given at decrypt time — so the name is passed explicitly rather
# than read back from a filename.
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# A suffix on a name picks the backend; it is spelling, not identity. `ALPHA`, `ALPHA.cred` and
# `ALPHA.age` are one record, and the credential ID systemd-creds embeds is the bare name.
base_name() {
  local base="$1"
  base="${base%.age}"
  printf '%s' "${base%.cred}"
}

# The whole contract, printed by `credsctl` with no arguments. Everything here is also true of the
# code below; keep the two in step.
usage() {
  printf '%s\n' \
    "usage: credsctl <list|encrypt|decrypt|rm> [NAME] ..." \
    "" \
    "  list                        every record in $creds_dir — systemd's own store via systemd-creds, anything else listed here" \
    "  encrypt NAME                prompts on a terminal (echo off, one line); pipe or pass FILE for multi-line" \
    "  encrypt NAME [FILE]         encrypt a file instead of stdin" \
    "  encrypt NAME.age            encrypt to $recipients (one recipient per line) instead of this machine" \
    "  decrypt NAME [NAME...]      print the secrets to stdout, one record per line" \
    "  decrypt --env NAME...       print KEY=VALUE lines, KEY being the credential name" \
    "  decrypt --env ... -- CMD    run CMD with the secrets in its environment; quote it (sh -c '...') or read it with printenv, since your shell expands \$NAME before credsctl runs" \
    "  rm NAME [NAME...]           remove these credentials — records are immutable, so a change is rm then encrypt" \
    "" \
    "  backends                    .cred = this machine, no prompt; .age = portable, needs $identity on a terminal" \
    "  overrides                   CREDS_DIR, CREDENTIALS_DIRECTORY, CREDS_IDENTITY, CREDS_RECIPIENTS" \
    "  exit codes                  0 ok · 1 bad usage · 2 no such record · 3 encrypt or decrypt failed"
}

# One row of `list`. systemd's own rows carry encrypted/signed flags we cannot derive from a file,
# so they come from systemd-creds; every other record is described from the file itself.
show_record() {
  local mode
  mode=$(stat -c '%a' "$1")
  printf '%-20s %s  %sB  %s\n' "$(basename "$1")" \
    "$([[ $mode == 400 ]] && echo secure || echo insecure)" "$(stat -c %s "$1")" "$1"
}

cmd_list() {
  # systemd-creds only ever reports its own store (~/.local/share/credentials). Listing it beside
  # $CREDS_DIR is honest only when they are the same directory; pointed elsewhere, the records
  # there are listed here and systemd's store is not reported at all.
  local sys_dir="${XDG_USER_DATA_DIRECTORY:-$HOME/.local/share}/credentials" f
  shopt -s nullglob
  if [[ $creds_dir == "$sys_dir" ]]; then
    systemd-creds list --user || die "systemd-creds list failed" 3
  else
    for f in "$creds_dir"/*.cred; do show_record "$f"; done
  fi
  for f in "$creds_dir"/*.age; do show_record "$f"; done
}

cmd_encrypt() {
  local name="${1:-}" file="${2:-}" target args=() line secret ext=cred id
  # One credential per call: a record holds one secret, and a second name would be read as a file.
  [[ $# -le 2 ]] || die "encrypt takes one credential at a time (got $*)"
  valid_name "$name" || die "invalid record name '$name' (a credential ID: letters, digits, . _ -)"
  if [[ $name == *.age ]]; then ext=age; fi
  id="$(base_name "$name")"
  target="$creds_dir/$id.$ext"
  [[ ! -e $target ]] || die "record exists: $target — records are immutable, remove it to change it"

  # shortcut: buffered in a variable rather than streamed, which strips a trailing newline and
  # puts the secret in this process's memory (never on disk). Upgrade to a stream if a record
  # must preserve exact bytes.
  if [[ -n $file ]]; then
    [[ -r $file ]] || die "cannot read $file"
    secret=$(cat -- "$file")
  elif [[ -t 0 ]]; then
    # A terminal, not a pipe: prompt. -s keeps the secret out of the terminal's scrollback,
    # so a one-line secret is typed here rather than piped. Pipe or pass a FILE for multi-line.
    read -rs -p "secret for $name: " secret || die "no secret typed"
  else
    secret=$(cat)
  fi
  [[ -n $secret ]] || die "empty secret: nothing written"

  mkdir -p "$creds_dir"
  if [[ $ext == age ]]; then
    [[ -r $recipients ]] || die "no recipient file: $recipients (one recipient per line)"
    while IFS= read -r line; do
      [[ -n $line && $line != '#'* ]] && args+=(-r "$line")
    done <"$recipients"
    [[ ${#args[@]} -gt 0 ]] || die "no recipients in $recipients"
    printf '%s' "$secret" | age "${args[@]}" -o "$target" || die "age encrypt failed for $name" 3
  else
    printf '%s' "$secret" | systemd-creds encrypt --user --name "$id" - "$target" ||
      die "systemd-creds encrypt failed for $name" 3
  fi
  chmod 400 "$target"
}

# The record a name resolves to, in REPLY: every name in decrypt and rm goes through here, so the
# name rule lives here too. A name must resolve to exactly one backend. REPLY rather than stdout
# keeps die() in this process instead of a subshell.
record_for() {
  local base cred age_file
  valid_name "$1" || die "invalid record name '$1'"
  base="$(base_name "$1")"
  cred="$creds_dir/$base.cred"
  age_file="$creds_dir/$base.age"
  [[ ! -e $cred || ! -e $age_file ]] ||
    die "both $base.cred and $base.age exist — remove one, a record name must resolve to one backend"
  REPLY=$cred
  [[ -e $REPLY ]] || REPLY=$age_file
  [[ -e $REPLY ]] || die "no record named '$1' in $creds_dir" 2
}

# Resolve every name before touching anything, so a name with no record removes nothing rather
# than half-clearing the list. -f covers a name repeated in one call; record_for already proved
# each file exists, so it cannot mask a real failure.
cmd_rm() {
  [[ $# -gt 0 ]] || die "rm needs at least one credential name"
  local targets=() name
  for name in "$@"; do
    record_for "$name"
    targets+=("$REPLY")
  done
  rm -f -- "${targets[@]}"
}

# The plaintext of one resolved record, on stdout. Backend choice is here and nowhere else; the
# credential ID systemd-creds checks is the record's bare name, read back from the file resolved.
decrypt_file() {
  local file="$1"
  if [[ $file == *.cred ]]; then
    systemd-creds decrypt --user --name "$(base_name "${file##*/}")" "$file" || die "cannot decrypt $file" 3
    return
  fi
  [[ -r $identity ]] || die "identity not readable: $identity"
  age -d -i "$identity" "$file" ||
    die "cannot decrypt $file — age reads the identity passphrase from a terminal only; a machine-local .cred record needs no prompt" 3
}

# Names, then optionally `-- CMD ARGS...`. Without a command the secrets go to stdout (one record
# per line, or KEY=VALUE with --env). With a command they are never printed: they are exported into
# the environment of CMD, which replaces this process.
cmd_decrypt() {
  local env_format=0 names=() cmd=() name plain assigns=() assign
  # --env is a marker, not a prefix: it may appear before any name.
  while [[ $# -gt 0 && ${1:-} != -- ]]; do
    [[ ${1:-} == --env ]] && {
      env_format=1
      shift
      continue
    }
    names+=("$1")
    shift
  done
  if [[ ${1:-} == -- ]]; then
    [[ $env_format == 1 ]] || die "a command needs --env so the secrets reach it as KEY=VALUE"
    [[ $# -gt 1 ]] || die "nothing after --"
    shift
    cmd=("$@")
  fi
  [[ ${#names[@]} -gt 0 ]] || die "decrypt needs at least one credential name"

  # shortcut: buffered per record like encrypt, so a trailing newline is stripped — encrypt strips
  # it on write too, so no record carries one. Upgrade to a stream if a record must keep exact bytes.
  for name in "${names[@]}"; do
    local base
    base="$(base_name "$name")"
    [[ $env_format == 0 || $base =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      die "'$name' is not a usable environment variable name"
    record_for "$name"
    plain=$(decrypt_file "$REPLY") || exit $?
    assigns+=("$base=$plain")
  done

  # With a command the secrets reach it through its environment only, never through stdout.
  [[ ${#cmd[@]} == 0 ]] || exec env -- "${assigns[@]}" "${cmd[@]}"
  for assign in "${assigns[@]}"; do
    [[ $env_format == 1 ]] && printf '%s\n' "$assign" || printf '%s\n' "${assign#*=}"
  done
}

case "${1:-}" in
list) cmd_list ;;
encrypt)
  shift
  cmd_encrypt "$@"
  ;;
decrypt)
  shift
  cmd_decrypt "$@"
  ;;
rm | remove)
  shift
  cmd_rm "$@"
  ;;
"" | -h | --help | help) usage ;;
*) die "unknown command '$1' — 'credsctl help' lists the commands" ;;
esac
