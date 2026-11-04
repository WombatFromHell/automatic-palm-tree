#!/usr/bin/env bash
# sopsctl — the sops plumbing behind .sops.json and .sops.yaml records.
#
# A record is a map whose values sops encrypts, in either of the two shapes sops supports, and the
# recipients live in the record's own metadata, so a field edit re-encrypts to whoever already holds
# it. The key lives in an identity file ($SOPS_AGE_FILE, where sops looks by itself), so decrypting
# needs no wallet, no command and no prompt; $SOPS_KEYS_CMD stays as the route for anyone who keeps a
# key in a wallet instead. Encrypting a PATH encrypts that file in place (`sops -e -i`) with the
# recipients taken from $SOPS_RULES, sops-nix's .sops.yaml of creation rules beside the records, named
# with --config so the current directory never decides who can read the record. Plaintext only ever
# goes to stdout.
#
# The suffix names a record's shape. The plaintext is read as json either way — jq, credsctl and the
# xilo wrapper parse it — and written back in the shape the name carries. Encrypting from stdin (no
# PATH, the stream credsctl uses) needs the type flags: without --input-type/--output-type sops reads
# stdin as binary and re-keys the payload under `data`, and no path_regex can match /dev/stdin, so
# that path names the recipient file instead. sops stamps `unencrypted_suffix: "_unencrypted"`, so a
# field named e.g. `host_unencrypted` stays readable in the file; that is the only way to keep a field
# in plain text.
set -uo pipefail

# A leading ~ arrives literal when it is quoted or comes from a variable, so path arguments and
# the env overrides get it expanded here. shortcut: the current user's home only; ~user paths stay
# as the shell gave them.
tilde() {
  case $1 in
  '~') printf '%s' "$HOME" ;;
  \~/*) printf '%s' "$HOME/${1:2}" ;;
  *) printf '%s' "$1" ;;
  esac
}

keys_cmd="${SOPS_KEYS_CMD:-kwallet-query -f flakeroot -r creds-identity kdewallet}"
recipients="$(tilde "${SOPS_RECIPIENTS:-$HOME/.local/share/credentials/recipient}")"
identity="$(tilde "${SOPS_AGE_FILE:-$HOME/.config/sops/age/keys.txt}")" # sops' own lookup path
rules="$(tilde "${SOPS_RULES:-$(dirname "$recipients")/.sops.yaml}")" # sops-nix's rules, beside the records

die() {
  echo "sopsctl: $1" >&2
  exit "${2:-1}"
}

# sops' own metadata block, in either shape: a file carrying it is a record, not plaintext.
encrypted_record() {
  grep -qE '^[[:space:]]*sops:' "$1" || grep -qE '"sops"[[:space:]]*:' "$1"
}

# The rules file in sops-nix's shape — recipients as anchors under `keys:`, one creation rule whose
# path_regex covers both record shapes wherever the records live. It is generated from the recipient
# file, so the rules and an explicit `--age` never drift apart.
rules_from_recipients() {
  awk '
    /^#/ { next }
    NF { key[++n] = $1 }
    END {
      if (n == 0) exit 1
      print "keys:"
      for (i = 1; i <= n; i++) print "  - &r" i, key[i]
      print "creation_rules:"
      print "  - path_regex: \\.sops\\.(json|yaml)$"
      print "    key_groups:"
      print "      - age:"
      for (i = 1; i <= n; i++) print "          - *r" i
    }
  ' "$recipients"
}

usage() {
  # These strings name variables rather than expand them, so they stay single-quoted — the same
  # directive lib/updater.sh carries for the same case.
  # shellcheck disable=SC2016
  printf '%s\n' \
    "usage: sopsctl <command> ..." \
    "" \
    '  init [--from-ssh KEY]   write an age identity to $SOPS_AGE_FILE, record its public key in $SOPS_RECIPIENTS $SOPS_RULES; with --from-ssh the pair comes from ssh-to-age instead of a fresh one, and KEY is the OpenSSH PRIVATE key without .pub (e.g. ~/.ssh/flakeroot_ed25519) — ssh-to-age reads its KEY.pub sibling and the ssh files stay untouched' \
    "  keys                    the recipient public keys (never a secret key)" \
    '  encrypt FILE            a plaintext *.sops.yaml or *.sops.json file encrypted IN PLACE, recipients from $SOPS_RULES (--config, so the cwd never matters); left 0400, and a file that is already a record is refused' \
    '  encrypt [--format json|yaml]  JSON on stdin -> ciphertext on stdout, for credsctl and pipes; yaml is the default shape, recipients from $SOPS_RECIPIENTS; the caller names the file and its mode' \
    "  decrypt FILE            plaintext JSON on stdout — json whatever the record's own shape is" \
    "  get FIELD FILE          one field's value" \
    "  set FIELD FILE          replace one field, re-encrypted to the record's own recipients in its own shape; the new value comes from stdin or a prompt, never an argument" \
    '  rekey FILE ...          re-encrypt records to $SOPS_RECIPIENTS, each keeping its own shape' \
    "  recipients FILE         the recipients embedded in a record, read from its metadata without decrypting" \
    "  protected KEY         say if an OpenSSH identity needs a passphrase: exit 0 yes, 1 no" \
    "  verify FILE             decrypt to /dev/null: exit 0 means the MAC is intact, no plaintext printed" \
    '  reset [--force]         delete the sops environment so init starts fresh: the identity, the rules file, the recipient file, and every *.sops.json / *.sops.yaml record in the credentials dir; only *.cred records stay. Without --force this only names those files and exits 1, because deleting the identity makes every record unreadable for good and deleting the recipient file drops the invite list for every other machine' \
    "" \
    "  overrides               SOPS_AGE_FILE (the identity), SOPS_RULES (the .sops.yaml of creation rules), SOPS_KEYS_CMD (a wallet-backed key instead), SOPS_RECIPIENTS (who can read a record)" \
    "  exit codes              0 ok · 1 bad usage · 2 no such record · 3 encrypt or decrypt failed; protected also exits 1 for an unlocked identity"
}

# An identity FILE outranks the key COMMAND: with a file, sops reads it itself, so no subprocess
# runs and nothing prompts. The command remains the route for a key that lives in a wallet.
run_sops() {
  if [[ -r $identity ]]; then
    SOPS_AGE_KEY_FILE="$identity" sops "$@"
  else
    SOPS_AGE_KEY_CMD="$keys_cmd" sops "$@"
  fi
}

# A stream encrypt names the recipients itself with --age on /dev/stdin, so sops' own rules-file
# lookup has to be switched off for it. sops reads a .sops.yaml from the CURRENT directory for ANY
# encrypt, no path_regex in one can match /dev/stdin, and cmd_init writes that file into the records
# dir — measured on sops 3.13.3 here: without this flag, `cd
# ~/.local/share/credentials && credsctl encrypt ALPHA.sops.json` dies 'error loading config: no
# matching creation rules found' even though --age names the key. A file encrypt keeps the rules file
# and names it with --config instead.
sops_no_rules=(--config /dev/null)

recipient_list() {
  [[ -r $recipients ]] || die "no recipient file: $recipients (one age public key per line)"
  grep -v '^#' "$recipients" | paste -sd, -
}

need_file() { [[ -f $1 ]] || die "no record: $1" 2; }

# A record is a *.sops.json or a *.sops.yaml file: the suffix is its shape, and a .cred belongs to
# systemd-creds, which sops has no format for.
record_suffix() {
  case $1 in
  *.json) printf json ;;
  *.yaml) printf yaml ;;
  *) printf '' ;;
  esac
}

need_record() {
  need_file "$1"
  [[ -n $(record_suffix "$1") ]] || die "no record: $1 — a record is *.sops.json or *.sops.yaml" 2
}

# The write side needs a shape, in REPLY: a name carries its suffix, a stream without a name defaults
# to yaml, and --format is for exactly that stream. A name and a flag that disagree are refused, so a
# *.json name never holds yaml ciphertext. REPLY rather than stdout keeps die() in this process
# instead of a command substitution whose status is lost.
record_format() {
  local name=${1:-} format=${2:-} suffix
  case $format in
  '' | json | yaml) ;;
  *) die "unknown format: $format (json or yaml)" 1 ;;
  esac
  if [[ -n $name ]]; then
    suffix=$(record_suffix "$name")
    [[ -n $suffix ]] || die "no record: $name" 2
    [[ -n $format ]] || format="$suffix"
    [[ $format == "$suffix" ]] || die "$name is a $suffix record; --format=$format says otherwise" 1
    REPLY=$format
    return
  fi
  REPLY=${format:-yaml}
}

# sops' metadata block is json in a *.json record and yaml in a *.yaml one, so a parser that assumes
# one shape reads only one of them. The recipients come out of the block with one match that
# tolerates either: quoted or not, and whatever follows the key is the value.
meta_values() {
  awk -v key="$1" 'BEGIN { re = "\"?" key "\"?[ \t]*:[ \t]*\"*" }
    {
      if (match($0, re)) {
        rest = substr($0, RSTART + RLENGTH)
        sub(/[" \t,].*$/, "", rest)
        print rest
      }
    }' "$2" | paste -sd, -
}

need_field() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid field name '$1' (letters, digits, _)" 1; }

# An OpenSSH private key names its cipher in the header: `aes256-ctr` plus `bcrypt` when it is
# encrypted at rest, `none` when it is not. Decoding the base64 body is the only honest probe, because
# ssh-keygen takes a passphrase from /dev/tty and a redirected run reports success either way.
# shortcut: the new OpenSSH format only — a pre-2014 PEM key prints 'unlocked' and ssh-to-age then
# reports it cannot convert, which is the same exit path a bad keypair already takes.
ssh_identity_protected() {
  awk '/BEGIN OPENSSH PRIVATE KEY/{p=1;next} /END OPENSSH/{p=0} p' "$1" | tr -d '\n' |
    base64 -d 2>/dev/null | LC_ALL=C grep -qE 'bcrypt|scrypt|aes(128|192|256)-(ctr|cbc)|3des-cbc|des-ede3-cbc|chacha20-poly1305'
}

cmd_protected() {
  [[ $# -eq 1 ]] || die "protected needs one OpenSSH identity" 1
  [[ -r $1 ]] || die "no identity: $1" 2
  if ssh_identity_protected "$1"; then
    printf 'passphrase-protected — sopsctl init --from-ssh will ask for it at the terminal (export SSH_TO_AGE_PASSPHRASE for a caller with no terminal)\n'
  else
    printf 'unlocked — ssh-to-age reads it with no prompt\n'
    exit 1
  fi
}

# The passphrase comes from one place: the terminal, read with echo off into the one variable that
# receives it, and handed to ssh-to-age in SSH_TO_AGE_PASSPHRASE. That variable is ssh-to-age's only
# passphrase input (measured here on the release nixpkgs ships, ssh-to-age 1.2.0: `strings` finds the
# name SSH_TO_AGE_PASSPHRASE and no -stdinpass, and the usage block lists only -i, -o, -private-key),
# and the command runs </dev/null so ssh-to-age cannot reach a terminal of its own. A caller with no
# terminal — a unit, a script, a GUI launcher — exports the variable itself and this prompt is skipped;
# with neither the read fails and the message names what to export. shortcut: a blank read is not a
# passphrase, so it is refused rather than tried.
# No desktop helper belongs on this path and none may be added: ssh-to-age is not ssh, it never reads
# SSH_ASKPASS, so a helper here could only be called by hand — and ksshaskpass on this host (6.8.2,
# measured) cannot even do that: its config dir is not writable, so it raises an error dialog for every
# attempt, floods the fontconfig warnings Qt prints on startup, and exits non-zero.
read_origin_passphrase() { # $1 = the keypair to name, passphrase on stdout
  local keypair="$1" pass
  printf 'passphrase for %s (used once here, never stored): ' "$keypair" >&2
  read -rs pass || return 1
  printf '%s' "$pass"
}

# ssh-to-age turns an OpenSSH keypair into an age keypair. The ssh key is the origin: it stays on
# disk behind its passphrase, and nothing here copies, unlocks or rewrites it. The age pair is the
# disposable half — regenerating it with the same command is how you replace a lost identity. The
# passphrase goes to ssh-to-age in its own environment variable, so a protected origin works with no
# terminal (callers may set SSH_TO_AGE_PASSPHRASE themselves) and the passphrase never reaches the
# store, the recipient file or git.
cmd_derive_from_ssh() {
  local keypair="$1" tmp err pass="${SSH_TO_AGE_PASSPHRASE:-}"
  [[ -r $keypair && -r "$keypair.pub" ]] ||
    die "need both halves of the ssh keypair: $keypair and $keypair.pub" 2
  # Deriving replaces the identity file, so records sealed to whatever key it held before would stop
  # opening. Refuse rather than discover that after the fact — a recipient rotation is `init` (no
  # --from-ssh) plus rekey, which keeps the identity on disk.
  if [[ -s $identity ]] && ! grep -q "# created: ssh-to-age from $keypair" "$identity" 2>/dev/null; then
    die "identity holds a different keypair: rekey the records to the new recipient, then restore the other identity by hand" 1
  fi
  # Ask before anything is converted or written, so a run that cannot get the passphrase leaves no
  # temp file and no half-written identity behind.
  if ssh_identity_protected "$keypair"; then
    [[ -n $pass ]] || {
      pass="$(read_origin_passphrase "$keypair")" ||
        die "cannot read the passphrase: type it, or export SSH_TO_AGE_PASSPHRASE for a caller with no terminal" 3
      [[ -n $pass ]] || die "no passphrase given" 3
    }
  fi
  pub="$(ssh-to-age -i "$keypair.pub")" || die "ssh-to-age cannot convert $keypair.pub" 3
  [[ -n $pub ]] || die "ssh-to-age printed no age public key for $keypair.pub" 3
  tmp="$(mktemp "${identity}.XXXXXX")" || die "cannot write beside $identity" 3
  if ssh_identity_protected "$keypair"; then
    # Measured here on the ssh-to-age release nixpkgs ships (1.2.0): its usage block takes only -i,
    # -o and -private-key, and SSH_TO_AGE_PASSPHRASE is its only passphrase input — there is no
    # -stdinpass to feed, so the variable is the route and the command runs </dev/null so it cannot
    # take the terminal behind our back. ponytail: if a release ever adds -stdinpass, switch here.
    # Its failure message embeds the raw key blob, so only the last line's reason after the blob's
    # closing quote is shown.
    err="$(mktemp "${tmp}.XXXXX")" || die "cannot write beside $tmp" 3
    SSH_TO_AGE_PASSPHRASE="$pass" ssh-to-age -private-key -i "$keypair" </dev/null >"$tmp" 2>"$err" ||
      {
        tail -n 1 "$err" | sed -e "s/.*': /sopsctl: /" >&2
        rm -f "$tmp" "$err"
        die "ssh-to-age cannot unlock $keypair — wrong passphrase?" 3
      }
    rm -f "$err"
  else
    ssh-to-age -private-key -i "$keypair" </dev/null >"$tmp" ||
      {
        rm -f "$tmp"
        die "ssh-to-age cannot convert $keypair" 3
      }
  fi
  # The comment lines are what cmd_init reads back on a rerun, so a derived identity and a
  # generated one are the same shape to everything downstream.
  printf '# created: ssh-to-age from %s\n# public key: %s\n' "$keypair" "$pub" >"$identity"
  cat "$tmp" >>"$identity"
  rm -f "$tmp"
  chmod 600 "$identity"
}

# Replace a record with a re-encrypted version of whatever stdin hands it. sops --set writes in
# place, which a 0400 record forbids, so every change goes through here and lands as 0400. The
# format is the record's own shape; sops writes its own metadata, so nothing is passed to restamp it.
rewrite() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")" || die "cannot write a temp record beside $1"
  run_sops -e --input-type json --output-type "$2" --age "$3" "${sops_no_rules[@]}" /dev/stdin >"$tmp" ||
    {
      rm -f "$tmp"
      die "cannot rewrite $1" 3
    }
  mv -- "$tmp" "$1"
  chmod 400 "$1"
}

cmd_encrypt() {
  local rec='' format=''
  while [[ $# -gt 0 ]]; do
    case $1 in
    --format)
      [[ ${2:-} == json || ${2:-} == yaml ]] || die "--format needs json or yaml" 1
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    *)
      [[ -z $rec ]] || die "encrypt takes one file at most" 1
      rec="$1"
      shift
      ;;
    esac
  done

  # A path argument is the plaintext to encrypt, in place — sops' own way, `sops -e -i FILE`. The
  # recipients come from the rules file, named with --config so the current directory never decides
  # who can read the record; with no rules file the recipient file names them. The suffix is the
  # shape, and the record is left 0400.
  if [[ -n $rec ]]; then
    need_record "$rec"
    encrypted_record "$rec" &&
      die "$rec is already a record — records are immutable: rm it and encrypt again, or use
sopsctl set FIELD FILE / sopsctl rekey FILE" 1
    record_format "$rec" "$format"
    local seal
    if [[ -r $rules ]]; then
      seal=(--config "$rules")
    else
      local recs
      recs="$(recipient_list)" || exit 1
      seal=(--age "$recs")
    fi
    run_sops -e -i "${seal[@]}" "$rec" ||
      die "cannot encrypt $rec — $rules has no creation rule for its suffix" 3
    chmod 400 "$rec"
    return
  fi

  # With no path the plaintext is JSON on stdin and the ciphertext is stdout, which is what credsctl
  # and a pipe use. A path_regex can never match /dev/stdin, so the recipients are named outright.
  # sops reads /dev/stdin and nobody closes a terminal, so on a tty this sits reading the keyboard
  # with no output at all. A terminal is not a pipe: name where the plaintext comes from instead.
  if [[ -t 0 ]]; then
    die "encrypt needs the plaintext JSON on stdin — a terminal is not a pipe. Pipe it in
(jq -n '{TOKEN:\"abc\"} | sopsctl encrypt --format yaml), write a plaintext FILE.sops.yaml and
run sopsctl encrypt FILE, or use credsctl encrypt NAME to be prompted for one secret, or
sopsctl set FIELD FILE to change one field of an existing record." 1
  fi
  record_format '' "$format"
  format="$REPLY"
  local recs
  recs="$(recipient_list)" || exit 1
  run_sops -e --input-type json --output-type "$format" --age "$recs" "${sops_no_rules[@]}" /dev/stdin ||
    die "encrypt failed" 3
}

# The plaintext is always json: jq, credsctl and the xilo wrapper parse it, whatever the record's
# own shape is.
cmd_decrypt() {
  need_record "$1"
  run_sops -d --output-type json "$1" || die "cannot decrypt $1" 3
}

cmd_get() {
  [[ $# -eq 2 ]] || die "get needs FIELD FILE" 1
  need_field "$1"
  need_record "$2"
  run_sops -d --output-type json --extract "[\"$1\"]" "$2" || die "cannot read $1 from $2" 3
}

# The new value never travels through argv: /proc/PID/cmdline is world-readable (0444 on this host),
# so an argument is readable by every user on the machine for the life of the process, and `jq --arg v`
# would have put it in a second argv as well. It comes from stdin — an anonymous pipe, no path, nothing
# to permission-check — or from a prompt with echo off, the rule credsctl encrypt already uses.
# shortcut: buffered in a variable, which drops a trailing newline and keeps the value in this process's
# memory rather than on disk. Upgrade to a stream if a value must keep exact bytes.
cmd_set() {
  [[ $# -eq 2 ]] || die "set needs FIELD FILE — the new value comes from stdin or a prompt, never an argument" 1
  need_field "$1"
  need_record "$2"
  local plain recs format value
  plain=$(run_sops -d --output-type json "$2") || die "cannot decrypt $2" 3
  recs=$(meta_values recipient "$2")
  [[ -n $recs ]] || die "no recipients in $2" 3
  record_format "$2"
  format="$REPLY"
  if [[ -t 0 ]]; then
    read -rs -p "new value for $1: " value || die "no value typed"
  else
    value=$(cat)
  fi
  [[ -n $value ]] || die "empty value: nothing written"
  # $ENV rather than --arg keeps the value out of jq's argv as well: an environment is mode 0400,
  # readable by your UID only.
  printf '%s' "$plain" | SOPSCTL_SET_VALUE="$value" jq -c --arg k "$1" '.[$k] = $ENV.SOPSCTL_SET_VALUE' |
    rewrite "$2" "$format" "$recs" ||
    die "cannot set $1 in $2" 3
}

# Recipient rotation: sops has no flag that changes recipients without a config file, so
# re-encrypting is the rekey.
cmd_rekey() {
  [[ $# -gt 0 ]] || die "rekey needs at least one record" 1
  local recs file format
  recs="$(recipient_list)" || exit 1
  for file in "$@"; do
    need_record "$file"
    record_format "$file"
    format="$REPLY"
    run_sops -d --output-type json "$file" |
      rewrite "$file" "$format" "$recs" ||
      die "cannot rekey $file" 3
  done
}

cmd_recipients() {
  need_record "$1"
  meta_values recipient "$1" | tr ',' '\n'
}

cmd_verify() {
  need_record "$1"
  run_sops -d --output-type json "$1" >/dev/null || die "cannot verify $1 — MAC or key failure" 3
}

# The secret half goes to an identity FILE on sops' own lookup path, so decrypting later needs no
# command, no wallet and no terminal; the public half goes to the recipient file and to a rules file
# beside the records in sops-nix's shape, which is what hands a hand-written record these keys. Raw
# `sops -e FILE` reads that rules file from the CURRENT directory, which is why the message names the
# directory to cd into; `sopsctl encrypt FILE` names the rules file outright, so its cwd never matters.
cmd_init() {
  local dir origin=''
  [[ ${1:-} == --from-ssh ]] && {
    origin="${2:-}"
    [[ -n $origin ]] || die "--from-ssh needs the ssh keypair to derive from" 1
  }
  [[ -z ${1:-} || ${1:-} == --from-ssh ]] ||
    die "init takes --from-ssh SSH_KEYPAIR or no argument" 1
  dir="$(dirname "$recipients")"
  mkdir -p "$(dirname "$identity")" || die "cannot create $(dirname "$identity")" 3
  if [[ -n $origin ]]; then
    if grep -q "# created: ssh-to-age from $origin" "$identity" 2>/dev/null; then
      printf 'identity already derived from %s in %s\n' "$origin" "$identity"
    else
      cmd_derive_from_ssh "$origin"
    fi
  elif [[ -r $identity ]]; then
    printf 'identity already in %s\n' "$identity"
  else
    age-keygen -o "$identity" || die "age-keygen failed" 3
    chmod 600 "$identity"
  fi
  pub="${pub:-$(grep '^# public key:' "$identity" | awk '{print $NF}')}"
  [[ -n $pub ]] || die "no public key line in $identity — put that recipient in $recipients yourself" 3
  mkdir -p "$dir"
  grep -qx "$pub" "$recipients" 2>/dev/null || printf '%s\n' "$pub" >>"$recipients"
  if [[ -f $rules ]]; then
    printf 'rules file already in %s — add %s to its key_groups, and check path_regex covers both shapes\n' "$rules" "$pub"
  else
    rules_from_recipients >"$rules" || die "no recipients in $recipients to write rules from" 3
    chmod 644 "$rules"
    printf 'rules file written to %s\n' "$rules"
  fi
  printf '\n%s is now the source of truth for your records:\n' "$identity"
  printf 'secret   %s at 0600 — the only file that can read them; keep it out of git, out of a share, and out of a screenshot\n' "$identity"
  printf 'public   %s in %s and %s — public keys, safe to commit\n' "$pub" "$recipients" "$rules"
  printf 'read     sops finds the identity itself, so nothing prompts: credsctl, sopsctl and a unit all just work\n'
  printf 'new      sopsctl encrypt NAME.sops.yaml (or NAME.sops.json) encrypts a plaintext file in place, from %s; a record you make by hand (sops -e FILE) gets these keys from that rules file, which sops reads from the CURRENT directory, so cd %s first\n' "$rules" "$dir"
  printf 'invite   append another machine\u2019s public key to %s, then sopsctl rekey FILE...\n' "$recipients"
  [[ -n $origin ]] || return 0
  printf '\nyour age keypair came from %s:\n' "$origin"
  printf 'origin   %s and %s.pub — read once, never copied, unlocked or rewritten: ssh still uses it, and its passphrase still applies\n' "$origin" "$origin"
  printf 'derived  %s is disposable: sopsctl init --from-ssh %s regenerates it, so losing it costs a passphrase, not a record\n' "$identity" "$origin"
}

# reset — the sops environment back to nothing, so init starts fresh. sopsctl owns four kinds of
# file: the identity, the rules file, the recipient file, and the records. Only a .cred stays —
# systemd-creds owns that, not sops. Records are encrypted and the identity is the only thing that
# can read them, so removing both is permanent; the recipient file lists every machine that holds a
# record, so it is the invite list, not a scratch file. Without --force this names the files and
# deletes nothing.
cmd_reset() {
  local force=0 files=() dir
  [[ -z ${1:-} || ${1:-} == --force ]] || die "reset takes --force or no argument" 1
  [[ ${1:-} == --force ]] && force=1
  # sops' own directory only when the identity really is sops' default file. A custom SOPS_AGE_FILE
  # points somewhere sopsctl has no business deleting, so just that file goes.
  if [[ $identity == "$HOME/.config/sops/age/keys.txt" ]]; then
    [[ -d $HOME/.config/sops ]] && files+=("$HOME/.config/sops")
  elif [[ -e $identity ]]; then
    files+=("$identity")
  fi
  [[ -e $rules ]] && files+=("$rules")
  [[ -e $recipients ]] && files+=("$recipients")
  dir="$(dirname "$recipients")"
  shopt -s nullglob
  files+=("$dir"/*.sops.json "$dir"/*.sops.yaml)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    printf 'nothing to reset — no identity, no rules file, no record in %s\n' "$dir"
    return 0
  fi
  printf '%s\n' "${files[@]}"
  [[ $force == 1 ]] ||
    die "reset deletes encrypted records whose only key is the identity above, and the recipient file that invites other machines: re-run with --force" 1
  rm -rf "${files[@]}"
  printf 'reset: %s removed — sopsctl init now starts fresh\n' "${#files[@]}"
}

# A ~ only reaches us literal when it was quoted or came through a variable, so the path arguments
# are expanded here before any command sees them. get and set take a FIELD first, so for those only
# the trailing file argument expands — a value now comes from stdin, where tilde() never touches it.
first=2
case "${1:-}" in
get | set) first=3 ;;
esac
if [[ $# -ge 2 ]]; then
  args=("${@:1:first-1}")
  for ((i = first; i <= "$#"; i++)); do args+=("$(tilde "${!i}")"); done
  set -- "${args[@]}"
fi

case "${1:-}" in
init)
  shift
  cmd_init "$@"
  ;;
protected)
  shift
  cmd_protected "$@"
  ;;
keys)
  recipient_list
  ;;
encrypt)
  shift
  cmd_encrypt "$@"
  ;;
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
reset)
  shift
  cmd_reset "$@"
  ;;
"" | -h | --help | help) usage ;;
*) die "unknown command '$1' — 'sopsctl help' lists the commands" ;;
esac
