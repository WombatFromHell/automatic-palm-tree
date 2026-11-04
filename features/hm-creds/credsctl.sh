#!/usr/bin/env bash
# credsctl — one record store, two backends.
#
# A record is one file in $CREDS_DIR (default ~/.local/share/credentials). The extension picks the
# backend:
#   <name>.cred  systemd-creds: decrypted silently, and bound to this machine (UID + machine-id),
#                so it cannot be carried to another host. One file holds exactly one secret, and
#                every decrypt pays the Varlink/polkit hop (~1.2s), so several secrets in a unit
#                cost several seconds.
#   <name>.sops.json / <name>.sops.yaml sops through sopsctl: portable across hosts, and sops opens
#                the age identity file itself ($SOPS_AGE_FILE, on sops' own lookup path), so no key
#                file is handed around, nothing prompts and no terminal is needed — a systemd unit or
#                an elevated push can read it. $SOPS_KEYS_CMD is the fallback for a key kept in a
#                wallet, and sops runs it only when that identity is missing or unreadable.
#                Machine-local automation records stay .cred.
#
# A sops record holds several secrets as fields whose names are the environment variables they are
# handed to (`encrypt NAME.sops.json --fields`, or the same for `NAME.sops.yaml`). The suffix is the
# record's shape, not a backend: credsctl decrypts a record once and reads the plaintext as json
# whatever the shape is, so a bundle fills a whole set in one sops process (~23ms) instead of one
# slow decrypt per secret.
#
# credsctl owns the record store: names, prompts, env export, exit codes. Every sops detail lives in
# sopsctl, which this delegates to.
#
# Records are immutable: encrypt never overwrites and every record is written 0400, so changing a
# secret means `rm <name>.<ext>` and encrypting again. Plaintext only ever goes to stdout.
set -uo pipefail

# The store: CREDS_DIR for a record store you point somewhere else, CREDENTIALS_DIRECTORY (what
# systemd sets for generated credentials) as the real location, and systemd's own store as the
# default. One chain here, so every caller -- xilo-wrapped, njust's _push -- reads the same store.
creds_dir="${CREDS_DIR:-${CREDENTIALS_DIRECTORY:-$HOME/.local/share/credentials}}"

die() {
  echo "credsctl: $1" >&2
  exit "${2:-1}"
}

# A record name doubles as a systemd credential ID, and systemd-creds compares the name embedded
# at encrypt time against the one given at decrypt time — so the name is passed explicitly rather
# than read back from a filename.
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# A suffix on a name picks the backend; it is spelling, not identity. `ALPHA`, `ALPHA.cred`,
# `ALPHA.sops.json` and `ALPHA.sops.yaml` are one record, and the credential ID systemd-creds embeds
# is the bare name.
base_name() {
  local base="$1"
  base="${base%.sops.json}"
  base="${base%.sops.yaml}"
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
    "  encrypt NAME.sops.json      encrypt through sopsctl to its recipients (one age public key per line) " \
    "  encrypt NAME.sops.yaml      the same record in sops' yaml shape — the suffix is the shape, the backend is the same" \
    "  encrypt NAME.sops.json --fields [FILE]  several secrets in one record, its field names being the environment variables they get handed to; json piped or from FILE, never typed (NAME.sops.yaml --fields too)" \
    "  decrypt NAME [NAME...]      print the secrets to stdout, one record per line (a bundle has no single secret to print)" \
    "  decrypt --env NAME...       print KEY=VALUE lines, KEY being the credential name — or every field of a bundle, with 'secret' taking the record's name" \
    "  decrypt --env ... -- CMD    run CMD with the secrets in its environment; quote it (sh -c '...') or read it with printenv, since your shell expands \$NAME before credsctl runs" \
    "  decrypt FILE                one record by path — the same record as its NAME, and the shape a unit or a pipeline passes" \
    "  rm NAME [NAME...]           remove these credentials — records are immutable, so a change is rm then encrypt" \
    "" \
    "  backends                    .cred = this machine, no prompt, one secret per record; .sops.json and .sops.yaml = portable, key fetched by sopsctl, no terminal, and one record may hold several fields" \
    "  overrides                   CREDS_DIR, CREDENTIALS_DIRECTORY; sopsctl takes SOPS_AGE_FILE (the identity file), SOPS_RULES (creation rules for new records), SOPS_KEYS_CMD (a wallet key), SOPS_RECIPIENTS (who can read a record)" \
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
  for f in "$creds_dir"/*.sops.json "$creds_dir"/*.sops.yaml; do show_record "$f"; done
}

cmd_encrypt() {
  local fields=0 pos=() arg name file ext=cred id secret json
  # --fields is a marker, like --env: it may sit before or after the name. Everything else stays
  # positional, so a second name is still one credential too many.
  for arg in "$@"; do
    [[ $arg == --fields ]] && fields=1 || pos+=("$arg")
  done
  [[ ${#pos[@]} -le 2 ]] || die "encrypt takes one credential at a time (got ${pos[*]})"
  name="${pos[0]:-}"
  file="${pos[1]:-}"
  valid_name "$name" || die "invalid record name '$name' (a credential ID: letters, digits, . _ -)"
  [[ $name == *.sops.json ]] && ext=sops.json
  [[ $name == *.sops.yaml ]] && ext=sops.yaml
  [[ $fields == 0 || $ext == sops.* ]] ||
    die "--fields writes several secrets into one record, which is a .sops shape — encrypt NAME.sops.json or NAME.sops.yaml for one secret"
  id="$(base_name "$name")"
  target="$creds_dir/$id.$ext"
  [[ ! -e $target ]] || die "record exists: $target — records are immutable, remove it to change it"

  if [[ $fields == 1 ]]; then
    # A bundle is several secrets in one sops record whose field names ARE the environment variables
    # they get handed to, so one decrypt fills a whole set (~23ms, against ~1.2s per .cred record).
    # There is no prompt path: json typed at a terminal is echoed, so the object is piped or read
    # from FILE. jq checks the shape before anything is encrypted — a key must be a name a shell can
    # expand (never sops' own metadata key) and a value a non-empty string; a multi-line value is
    # stored as escapes and comes back as real newlines.
    [[ -t 0 ]] && die "--fields needs the json object piped or passed as FILE — typed at a terminal it is echoed"
    # shortcut: buffered like the single-secret path, so the json sits in this process's memory
    # rather than on disk. Upgrade to a stream if a bundle must keep exact bytes.
    json=$(jq -c -e '
      if type == "object" and (length > 0) and
        ([keys[] | (test("^[A-Za-z_][A-Za-z0-9_]*$") and . != "sops")] | all) and
        ([.[] | (type == "string" and length > 0)] | all)
      then . else empty end' "${file:--}") ||
      die "fields must be a json object of non-empty string secrets with env-shaped keys"
  else
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
    # sops takes the plaintext as json whatever the record's shape is, and encrypts every value in
    # it, so the one secret is exactly one field — --arg keeps a multi-line secret intact.
    json=$(jq -c -n --arg v "$secret" '{secret:$v}')
  fi

  mkdir -p "$creds_dir"
  # The redirect creates the file before the delegate runs, so a failure has to remove it rather
  # than leave an empty record.
  if [[ $ext == sops.* ]]; then
    # The suffix the name carried is the shape sops writes; without --format sopsctl defaults to yaml.
    printf '%s' "$json" | sopsctl encrypt --format "${ext#sops.}" >"$target" ||
      {
        rm -f "$target"
        die "sopsctl encrypt failed for $name" 3
      }
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
  local base cred sops_json sops_yaml want=''
  valid_name "$1" || die "invalid record name '$1'"
  base="$(base_name "$1")"
  cred="$creds_dir/$base.cred"
  sops_json="$creds_dir/$base.sops.json"
  sops_yaml="$creds_dir/$base.sops.yaml"
  # A suffix spelled on the name is an explicit request for that file, so it resolves even when
  # several exist — that is how the xilo wrapper asks for the fast backend. Without a suffix the
  # name is ambiguous: .cred wins, and a name that matches more than one file is refused, not guessed.
  [[ $1 == *.cred ]] && want=$cred
  [[ $1 == *.sops.json ]] && want=$sops_json
  [[ $1 == *.sops.yaml ]] && want=$sops_yaml
  if [[ -n $want ]]; then
    [[ -e $want ]] || die "no record named '$1' in $creds_dir" 2
    REPLY=$want
    return
  fi
  local found=()
  for f in "$cred" "$sops_json" "$sops_yaml"; do
    [[ -e $f ]] && found+=("${f##*/}")
  done
  [[ ${#found[@]} -le 1 ]] ||
    die "more than one record for $base: ${found[*]} — remove one, or name the backend you mean"
  REPLY=$cred
  [[ -e $REPLY ]] || REPLY=$sops_json
  [[ -e $REPLY ]] || REPLY=$sops_yaml
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

# The plaintext of one resolved record. Backend choice is here and nowhere else; the credential ID
# systemd-creds checks is the record's bare name, read back from the file resolved. A sops record
# comes back as its whole json — one sops process per record, whichever fields are asked for.
decrypt_cred() {
  systemd-creds decrypt --user --name "$(base_name "${1##*/}")" "$1"
}

decrypt_sops() { sopsctl decrypt "$1"; }

# Names, then optionally `-- CMD ARGS...`. Without a command the secrets go to stdout (one record
# per line, or KEY=VALUE with --env). With a command they are never printed: they are exported into
# the environment of CMD, which replaces this process.
cmd_decrypt() {
  local env_format=0 names=() cmd=() assigns=() name base plain json fields assign key got
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
    base="$(base_name "$name")"
    [[ $env_format == 0 || $base =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      die "'$name' is not a usable environment variable name — --env takes a bare credential name (XILO, or XILO.sops.yaml), resolved inside $creds_dir; a path belongs to sopsctl"
    record_for "$name"
    if [[ $REPLY == *.cred ]]; then
      plain=$(decrypt_cred "$REPLY") || die "cannot decrypt $REPLY" 3
      assigns+=("$base=$plain")
      continue
    fi
    json=$(decrypt_sops "$REPLY") ||
      die "cannot decrypt $REPLY — sops needs a key: the identity file at \$SOPS_AGE_FILE, or \$SOPS_KEYS_CMD when there is none; a machine-local .cred record needs no key at all" 3
    if [[ $env_format == 0 ]]; then
      # Plain decrypt prints one secret and nothing else; a bundle has no single secret to print,
      # so the message names the form that can read it instead of reporting a key problem that
      # is not the cause.
      plain=$(printf '%s' "$json" | jq -r '.secret // empty') || die "cannot read $REPLY" 3
      [[ -n $plain ]] ||
        die "record '$name' has no 'secret' field — decrypt --env $name prints its fields as KEY=VALUE" 2
      assigns+=("$base=$plain")
      continue
    fi
    # A bundle's fields are environment variables. Assignments are read NUL-separated straight from
    # jq — a command substitution would drop the NULs, and split on newlines a multi-line secret
    # would arrive truncated. Only a non-empty string is a secret, matching what encrypt accepts; a
    # key no shell can expand is skipped rather than exported as a dead variable; a field named
    # `secret` is the record's own secret, so it takes the record's name.
    got=0
    while IFS= read -r -d '' assign; do
      key="${assign%%=*}"
      [[ $key == secret ]] && key="$base"
      [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      assigns+=("$key=${assign#*=}")
      got=1
    done < <(printf '%s' "$json" |
      jq -j 'to_entries[] | select(.value | type == "string" and length > 0) | "\(.key)=\(.value)\u0000"')
    [[ ${got:-0} == 1 ]] || die "record '$name' holds no field a shell can name" 3
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
