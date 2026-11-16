#!/usr/bin/env bash
# credsctl — one record store, two backends, one command.
#
# A record is one file in $creds_dir (default ~/.local/share/credentials). The suffix picks the
# backend and the shape:
#   <name>.cred  systemd-creds: decrypted silently, and bound to this machine (UID + machine-id),
#                so it cannot be carried to another host. One file holds exactly one secret, and
#                every decrypt pays the Varlink/polkit hop (~1.2s), so several secrets in a unit
#                cost several seconds.
#   <name>.sops.json / <name>.sops.yaml sops: portable across hosts, and sops opens the age identity
#                file itself ($SOPS_AGE_FILE, on sops' own lookup path), so no key file is handed
#                around, nothing prompts and no terminal is needed — a systemd unit or an elevated
#                push can read it. $SOPS_KEYS_CMD is the fallback for a key kept in a wallet, and
#                sops runs it only when that identity is missing or unreadable. The record holds
#                several secrets as fields whose names are the environment variables they are handed
#                to, so one bundle fills a whole set in one sops process (~23ms) rather than one
#                slow decrypt per secret.
#
# The sops half is the plumbing below: the identity, sops-nix's creation rules, recipients, and
# sealing. A record's recipients live in its own metadata, so a field edit re-encrypts to whoever
# already holds it. Encrypting a plaintext FILE seals it IN PLACE (`sops -e -i`) with recipients taken
# from $SOPS_RULES, named with --config so the current directory never decides who can read the
# record; that is the recommended route, and it takes several files at once. Plaintext only ever goes
# to stdout.
#
# Two roots move the whole environment for a store that lives elsewhere: $AGE_ROOT names the directory
# the secret half lives in (its own age/keys.txt, default ~/.config/sops) and $CREDS_ROOT the directory
# the public half lives in (rules, records, and a recipient file only if someone made one — default
# ~/.local/share/credentials). Unset, every path below is today's default.
#
# The suffix names a record's shape. The plaintext is read as json either way — jq, xilo and every
# unit parse it — and written back in the shape the name carries. Encrypting from stdin needs the
# type flags: without --input-type/--output-type sops reads stdin as binary and re-keys the payload
# under `data`, and no path_regex can match /dev/stdin, so that path names the recipients outright
# instead. sops stamps `unencrypted_suffix: "_unencrypted"`, so a field named e.g. `host_unencrypted`
# stays readable in the file; that is the only way to keep a field in plain text.
#
# Records are immutable: encrypt never overwrites and every record is written 0400, so changing a
# secret is `set` (one field) or `rm` then encrypt.
set -uo pipefail

# A leading ~ arrives literal when it is quoted or comes from a variable, so path arguments and the
# env overrides get it expanded here. shortcut: the current user's home only; ~user paths stay as the
# shell gave them.
tilde() {
  case $1 in
  '~') printf '%s' "$HOME" ;;
  \~/*) printf '%s' "$HOME/${1:2}" ;;
  *) printf '%s' "$1" ;;
  esac
}

# Two roots, one per half of the environment, overrides over today's defaults, and the per-file
# overrides still outrank a root.
age_root="$(tilde "${AGE_ROOT:-$HOME/.config/sops}")"
creds_root="$(tilde "${CREDS_ROOT:-$HOME/.local/share/credentials}")"
# The store, one chain so every caller -- xilo-wrapped, njust's _push -- reads the same directory:
# CREDS_DIR for a store you point somewhere else, CREDENTIALS_DIRECTORY (what systemd sets for
# generated credentials), CREDS_ROOT for the whole store a flake deploys, and systemd's own as the
# default. The rules and recipient files stay beside CREDS_ROOT, not the unit's directory.
creds_dir="$(tilde "${CREDS_DIR:-${CREDENTIALS_DIRECTORY:-$creds_root}}")"
keys_cmd="${SOPS_KEYS_CMD:-kwallet-query -f flakeroot -r creds-identity kdewallet}"
# The rules file is the public half's home: sops-nix's creation rules, beside the records, and the
# place recipients are kept. The recipient file is optional — read if the user made one, never written.
rules="$(tilde "${SOPS_RULES:-$creds_root/.sops.yaml}")"
recipients="$(tilde "${SOPS_RECIPIENTS:-$creds_root/recipient}")"
identity="$(tilde "${SOPS_AGE_FILE:-$age_root/age/keys.txt}")" # sops' own lookup path

die() {
  echo "credsctl: $1" >&2
  exit "${2:-1}"
}

# A record name doubles as a systemd credential ID, and systemd-creds compares the name embedded at
# encrypt time against the one given at decrypt time — so the name is passed explicitly rather than
# read back from a filename.
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

# A record is a *.json or a *.yaml file: the suffix is its shape, and a .cred belongs to
# systemd-creds, which sops has no format for. Its suffix is also the format sops writes, so there is
# no --format to contradict it.
need_record() {
  [[ -f $1 ]] || die "no record: $1" 2
  [[ $1 == *.json || $1 == *.yaml ]] || die "no record: $1 — a record is *.sops.json or *.sops.yaml" 2
}

need_field() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid field name '$1' (letters, digits, _)" 1; }

usage() {
  # These strings name variables rather than expand them, so they stay single-quoted — the same
  # directive lib/updater.sh carries for the same case.
  # shellcheck disable=SC2016
  printf '%s\n' \
    "usage: credsctl <command> ..." \
    "" \
    "  list                        every record in \$creds_dir — systemd's own store via systemd-creds, anything else listed here" \
    "  encrypt NAME                prompts on a terminal (echo off, one line); pipe or pass FILE for multi-line" \
    "  encrypt NAME [FILE]         encrypt a file instead of stdin" \
    '  encrypt FILE...             a plaintext *.sops.yaml or *.sops.json sealed IN PLACE, recipients from $SOPS_RULES (--config, so the cwd never matters); left 0400, and several files at once' \
    "  encrypt NAME.sops.json      one secret sealed from stdin or the prompt into the store as json" \
    "  encrypt NAME.sops.yaml      the same record in sops' yaml shape — the suffix is the shape, the backend is the same" \
    "  decrypt NAME [NAME...]      print the secrets to stdout, one record per line (a bundle has no single secret to print)" \
    "  decrypt --env NAME...       print KEY=VALUE lines, KEY being the credential name — or every field of a bundle, with 'secret' taking the record's name" \
    "  decrypt --env ... -- CMD    run CMD with the secrets in its environment; quote it (sh -c '...') or read it with printenv, since your shell expands \$NAME before credsctl runs" \
    "  decrypt FILE                one record by path — the same record as its NAME, and the shape a unit or a pipeline passes" \
    "  rm NAME [NAME...]           remove these credentials — records are immutable, so a change is rm then encrypt" \
    "" \
    "  keys                        the recipient public keys (never a secret key)" \
    '  init [--from-ssh KEY]       write an age identity to $SOPS_AGE_FILE and record its public key in $SOPS_RULES, sops-nix creation rules; an existing rules file is left alone, and no recipient file is created; with --from-ssh the pair comes from ssh-to-age instead of a fresh one, and KEY is the OpenSSH PRIVATE key without .pub (e.g. ~/.ssh/flakeroot_ed25519) — ssh-to-age reads its KEY.pub sibling and the ssh files stay untouched' \
    "  set FIELD FILE              replace one field, re-encrypted to the record's own recipients in its own shape; the new value comes from stdin or a prompt, never an argument" \
    '  rekey FILE...               re-encrypt records to $SOPS_RULES (plus an optional $SOPS_RECIPIENTS), each keeping its own shape' \
    "  recipients FILE             the recipients embedded in a record, read from its metadata without decrypting" \
    "  verify FILE                 decrypt to /dev/null: exit 0 means the MAC is intact, no plaintext printed" \
    "  protected KEY               say if an OpenSSH identity needs a passphrase: exit 0 yes, 1 no" \
    '  reset [--force]             delete the sops environment so init starts fresh: the identity, the rules file, a recipient file if one exists, and every *.sops.json / *.sops.yaml record in the credentials dir; only *.cred records stay. Without --force this only names those files and exits 1, because deleting the identity makes every record unreadable for good and deleting the rules file drops the invite list for every other machine' \
    "" \
    "  notes (not commands):" \
    "  backend rule                .cred = this machine, no prompt, one secret per record; .sops.json and .sops.yaml = portable, key read by sops itself, no terminal, and one record may hold several fields" \
    "  env overrides               CREDS_DIR, CREDENTIALS_DIRECTORY, CREDS_ROOT (a whole store: records, rules, and a recipient file only if you made one — e.g. CREDS_ROOT=./secrets for a flake-deployed store); AGE_ROOT (where the age identity lives, its own age/keys.txt), SOPS_AGE_FILE (one identity file), SOPS_RULES (creation rules for new records), SOPS_KEYS_CMD (a wallet key), SOPS_RECIPIENTS (an optional recipient file whose keys join the rules)" \
    "  exit codes                  0 ok · 1 bad usage · 2 no such record · 3 encrypt or decrypt failed; protected also exits 1 for an unlocked identity"
  # The overrides above are what the lines above actually resolved to, so the store is printed too.
  printf '\n  store: %s\n' "$creds_dir"
}

# One row of `list`. systemd's own rows carry encrypted/signed flags we cannot derive from a file, so
# they come from systemd-creds; every other record is described from the file itself.
show_record() {
  local mode size
  read -r mode size < <(stat -c '%a %s' "$1")
  printf '%-20s %s  %sB  %s\n' "${1##*/}" \
    "$([[ $mode == 400 ]] && echo secure || echo insecure)" "$size" "$1"
}

cmd_list() {
  # systemd-creds only ever reports its own store (~/.local/share/credentials). Listing it beside
  # $creds_dir is honest only when they are the same directory; pointed elsewhere, the records there
  # are listed here and systemd's store is not reported at all.
  local sys_dir="$HOME/.local/share/credentials" f out
  shopt -s nullglob
  if [[ $creds_dir == "$sys_dir" ]]; then
    # systemd-creds lists every FILE in its store, header included. Only its *.cred rows belong here:
    # its rows would report the age records a second time below, and its store also holds the rules
    # file and a recipient file, which are not credentials. An empty store is not a failure.
    out="$(systemd-creds list --user)" || die "systemd-creds list failed" 3
    printf '%s\n' "$out" | grep -E '\.cred' || true
  else
    for f in "$creds_dir"/*.cred; do show_record "$f"; done
  fi
  for f in "$creds_dir"/*.sops.json "$creds_dir"/*.sops.yaml; do show_record "$f"; done
}

# An identity FILE outranks the key COMMAND: with a file, sops reads it itself, so no subprocess runs
# and nothing prompts. The command remains the route for a key that lives in a wallet.
run_sops() {
  if [[ -r $identity ]]; then
    SOPS_AGE_KEY_FILE="$identity" sops "$@"
  else
    SOPS_AGE_KEY_CMD="$keys_cmd" sops "$@"
  fi
}

# Age public keys named in a file, deduped in the order they appear: sops-nix's `keys:` anchors and
# their aliases, a json list, or one key per line all match. The regex is the public half only — an
# age secret key is upper-case AGE-SECRET-KEY and never printed. A file that is not there contributes
# nothing, so an optional file costs no check of its own.
age_keys() {
  grep -ohE 'age1[a-z0-9]+' "$@" 2>/dev/null | awk 'NF && !seen[$0]++' || true
}

# Who may read a record: the rules file first — sops-nix's creation rules, the shape sops itself
# reads and the one place recipients have to live — then the optional `recipient` file beside it,
# which is used only if someone made one. One grep over both files names a key in both once. `keys`
# is this command and the internal callers use it the same way.
cmd_keys() {
  local keys
  keys="$(age_keys "$rules" "$recipients")"
  [[ -n $keys ]] ||
    die "no recipients: neither $rules nor $recipients holds an age public key — credsctl init writes the rules file, or add keys to it yourself"
  printf '%s\n' "$keys" | paste -sd, -
}

# The rules file in sops-nix's shape — recipients as anchors under `keys:`, one creation rule whose
# path_regex covers both record shapes wherever the records live. It is written from the key list on
# stdin, so the rules and an explicit `--age` never drift apart.
rules_from_keys() {
  awk '
    /^#/ { next }
    NF && !seen[$1]++ { key[++n] = $1 }
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
  '
}

# sops' metadata block is json in a *.json record and yaml in a *.yaml one, so a parser that assumes
# one shape reads only one of them. The recipients come out of the block with one match that
# tolerates either: quoted or not, and whatever follows the key is the value. One line per recipient.
meta_values() {
  awk 'BEGIN { re = "\"?recipient\"?[ \t]*:[ \t]*\"*" }
    {
      if (match($0, re)) {
        rest = substr($0, RSTART + RLENGTH)
        sub(/[" \t,].*$/, "", rest)
        # An encrypted field of the record named `recipient` is data, not a recipient: sops writes
        # ciphertext as ENC[…], and no key can be one. Truncated at the first comma above, it would
        # otherwise read as a recipient sops refuses.
        if (rest ~ /^ENC\[/) next
        print rest
      }
    }' "$1"
}

# An OpenSSH private key names its cipher in the header: `aes256-ctr` plus `bcrypt` when it is
# encrypted at rest, `none` when it is not. Decoding the base64 body is the only honest probe,
# because ssh-keygen takes a passphrase from /dev/tty and a redirected run reports success either way.
# shortcut: the new OpenSSH format only — a pre-2014 PEM keypair is refused before this probe runs,
# see cmd_derive_from_ssh.
ssh_identity_protected() {
  awk '/BEGIN OPENSSH PRIVATE KEY/{p=1;next} /END OPENSSH/{p=0} p' "$1" | tr -d '\n' |
    base64 -d 2>/dev/null | LC_ALL=C grep -qE 'bcrypt|scrypt|aes(128|192|256)-(ctr|cbc)|3des-cbc|des-ede3-cbc|chacha20-poly1305'
}

cmd_protected() {
  [[ $# -eq 1 ]] || die "protected needs one OpenSSH identity" 1
  [[ -r $1 ]] || die "no identity: $1" 2
  if ssh_identity_protected "$1"; then
    printf 'passphrase-protected — credsctl init --from-ssh will ask for it at the terminal (export SSH_TO_AGE_PASSPHRASE for a caller with no terminal)\n'
  else
    printf 'unlocked — ssh-to-age reads it with no prompt\n'
    exit 1
  fi
}

# The passphrase comes from one place: the terminal, read with echo off into the one variable that
# receives it, and handed to ssh-to-age in SSH_TO_AGE_PASSPHRASE (its only passphrase input — see the
# call in cmd_derive_from_ssh, which runs </dev/null so ssh-to-age cannot reach a terminal of its own).
# A caller with no terminal exports the variable itself and this prompt is skipped; with neither, the
# read fails and the message names what to export. shortcut: a blank read is not a passphrase, so it
# is refused rather than tried.
# No desktop helper belongs on this path and none may be added: ssh-to-age is not ssh, it never reads
# SSH_ASKPASS, so a helper here could only be called by hand — and ksshaskpass on this host (6.8.2,
# measured) cannot even do that: its config dir is not writable, so it raises an error dialog for
# every attempt, floods the fontconfig warnings Qt prints on startup, and exits non-zero.
read_origin_passphrase() { # $1 = the keypair to name, passphrase on stdout
  local keypair="$1" pass
  printf 'passphrase for %s (used once here, never stored): ' "$keypair" >&2
  read -rs pass || return 1
  printf '%s' "$pass"
}

# ssh-to-age turns an OpenSSH keypair into an age keypair: the ssh key is the origin — never copied,
# unlocked or rewritten here, see USAGE.md — and the age pair is the disposable half, regenerable with
# this same command.
cmd_derive_from_ssh() {
  local keypair="$1" tmp err pub pass="${SSH_TO_AGE_PASSPHRASE:-}"
  [[ -r $keypair && -r "$keypair.pub" ]] ||
    die "need both halves of the ssh keypair: $keypair and $keypair.pub" 2
  # ssh-to-age parses the OpenSSH format only. A pre-2014 PEM keypair (`BEGIN RSA PRIVATE KEY`) fails
  # its conversion and the failure prints the whole key blob on stderr, so name the format and the fix
  # here, before anything is read or written.
  grep -q '^-----BEGIN OPENSSH PRIVATE KEY-----' "$keypair" ||
    die "$keypair is a legacy PEM keypair (-----BEGIN RSA PRIVATE KEY-----) — convert it in place first: ssh-keygen -o -f $keypair (it keeps the passphrase; nothing else changes)" 1
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
        tail -n 1 "$err" | sed -e "s/.*': /credsctl: /" >&2
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
  # The comment lines are what cmd_init reads back on a rerun, so a derived identity and a generated
  # one are the same shape to everything downstream.
  printf '# created: ssh-to-age from %s\n# public key: %s\n' "$keypair" "$pub" >"$identity"
  cat "$tmp" >>"$identity"
  rm -f "$tmp"
  chmod 600 "$identity"
}

# init writes the identity to sops' own lookup path and the rules file beside the records (header).
# The message below names the directory to `cd` into because raw `sops -e FILE` reads its rules from
# the current directory; `credsctl encrypt FILE` names the rules file outright.
cmd_init() {
  local dir id_dir origin=''
  [[ ${1:-} == --from-ssh ]] && {
    origin="${2:-}"
    [[ -n $origin ]] || die "--from-ssh needs the ssh keypair to derive from" 1
  }
  [[ -z ${1:-} || ${1:-} == --from-ssh ]] ||
    die "init takes --from-ssh SSH_KEYPAIR or no argument" 1
  dir="$(dirname "$rules")"
  id_dir="$(dirname "$identity")"
  mkdir -p "$id_dir" || die "cannot create $id_dir" 3
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
  pub="$(grep '^# public key:' "$identity" | awk '{print $NF}')"
  [[ -n $pub ]] || die "no public key line in $identity — put that recipient in $rules yourself" 3
  mkdir -p "$dir"
  # The recipients live in the rules file. init writes it only when it is not there yet, from this
  # identity's key plus whatever the store already names; a rules file a person wrote by hand is left
  # alone rather than rewritten, and an optional recipient file is never created or appended to.
  if [[ -f $rules ]]; then
    printf 'rules file already in %s — add %s to its key_groups, and check path_regex covers both shapes\n' "$rules" "$pub"
  else
    # This branch runs only when $rules is not there, so the keys are the optional recipient file
    # plus init's own public key — reading $rules here would read and write one file in one pipeline.
    # Recipients that already exist come first; the key just generated is the newest invite.
    {
      age_keys "$recipients"
      printf '%s\n' "$pub"
    } | rules_from_keys >"$rules" || die "no keys to write $rules from" 3
    chmod 644 "$rules"
    printf 'rules file written to %s\n' "$rules"
  fi
  printf '\n%s is now the source of truth for your records:\n' "$identity"
  printf 'secret   %s at 0600 — the only file that can read them; keep it out of git, out of a share, and out of a screenshot\n' "$identity"
  printf 'public   %s in %s — public keys, safe to commit\n' "$pub" "$rules"
  printf 'read     sops finds the identity itself, so nothing prompts: credsctl and a unit all just work\n'
  printf 'new      credsctl encrypt FILE.sops.yaml (or FILE.sops.json) seals a plaintext file in place, from %s; a record you make by hand (sops -e FILE) gets these keys from that rules file, which sops reads from the CURRENT directory, so cd %s first\n' "$rules" "$dir"
  printf 'invite   add a public key to the keys: block of %s, then credsctl rekey FILE...\n' "$rules"
  [[ -n $origin ]] || return 0
  printf '\nyour age keypair came from %s:\n' "$origin"
  printf 'origin   %s and %s.pub — read once, never copied, unlocked or rewritten: ssh still uses it, and its passphrase still applies\n' "$origin" "$origin"
  printf 'derived  %s is disposable: credsctl init --from-ssh %s regenerates it, so losing it costs a passphrase, not a record\n' "$identity" "$origin"
}

# Replace a record with a re-encrypted version of whatever stdin hands it. sops --set writes in
# place, which a 0400 record forbids, so every change goes through here and lands as 0400. The format
# is the record's own shape; sops writes its own metadata, so nothing is passed to restamp it.
rewrite() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")" || die "cannot write a temp record beside $1"
  run_sops -e --input-type json --output-type "$2" --age "$3" --config /dev/null /dev/stdin >"$tmp" ||
    {
      rm -f "$tmp"
      die "cannot rewrite $1" 3
    }
  mv -- "$tmp" "$1"
  chmod 400 "$1"
}

# Seal one plaintext record file in place (`sops -e -i`), its recipients taken from the rules file named
# with --config so the current directory never decides who may read the record — or from the optional
# recipient file when there is no rules file. sops refuses a file that already holds its metadata
# (exit 203), so nothing here guards against double-encrypting.
seal_in_place() {
  need_record "$1"
  local seal recs
  if [[ -r $rules ]]; then
    seal=(--config "$rules")
  else
    recs="$(cmd_keys)" || exit 1
    # A path_regex can never match a rules file that is not there, so the lookup is switched off and
    # the recipients are named outright.
    seal=(--age "$recs" --config /dev/null)
  fi
  run_sops -e -i "${seal[@]}" "$1" ||
    die "cannot seal $1 — see the sops error above" 3
  chmod 400 "$1"
}

# Encrypt a name that has no file behind it: one secret from stdin or the prompt, sealed into the
# store. A stream encrypt names the recipients itself with --age, because no path_regex can match
# /dev/stdin — measured on sops 3.13.3, without `--config /dev/null` a stream encrypt dies 'error
# loading config: no matching creation rules found'.
cmd_encrypt() {
  [[ $# -gt 0 ]] || die "encrypt needs a record name or a plaintext record file" 1
  # A plaintext record file is sealed in place, one sops process per file: sops takes only one
  # positional argument and silently ignores the rest (measured on 3.13.3). A path is always a seal,
  # and a bare name seals the plaintext file found under that name — inside the store, or in the
  # directory the command runs in; any other bare name is the stream route. A path of the wrong shape is
  # not there is 'no record' (2).
  if [[ ${1} == */* || ( ${1} == *.sops.* && ( -f "$1" || -f "$creds_dir/${1}" ) ) ]]; then
    for file in "$@"; do
      [[ ${file} == */* || -f $file ]] || file="$creds_dir/$file"
      [[ $file == *.sops.json || $file == *.sops.yaml ]] ||
        die "not a record file: $file — seal a plaintext *.sops.json or *.sops.yaml file" 1
      seal_in_place "$file"
    done
    return
  fi
  [[ $# -le 2 ]] || die "encrypt takes one credential at a time (got $#)"
  local name=$1 file=${2:-} ext=cred id secret target recs=''
  valid_name "$name" ||
    die "invalid record name '$name' (a credential ID: letters, digits, . _ -, or a *.sops.json|*.sops.yaml file to seal)" 1
  [[ $name == *.sops.json ]] && ext=sops.json
  [[ $name == *.sops.yaml ]] && ext=sops.yaml
  id="$(base_name "$name")"
  target="$creds_dir/$id.$ext"
  [[ ! -e $target ]] || die "record exists: $target — records are immutable, remove it to change it"

  # Recipients are resolved before the secret is asked for, so a run that cannot seal never leaves a
  # person typing into a prompt that is about to fail, and their absence is a usage error (1) rather
  # than a failed encrypt (3).
  if [[ $ext == sops.* ]]; then
    recs="$(cmd_keys)" || exit 1
  fi

  # shortcut: buffered in a variable rather than streamed, which strips a trailing newline and puts
  # the secret in this process's memory (never on disk). Upgrade to a stream if a record must
  # preserve exact bytes.
  if [[ -n $file ]]; then
    [[ -r $file ]] || die "cannot read $file"
    secret=$(cat -- "$file")
  elif [[ -t 0 ]]; then
    # A terminal, not a pipe: prompt. -s keeps the secret out of the terminal's scrollback, so a
    # one-line secret is typed here rather than piped. Pipe or pass a FILE for multi-line.
    read -rs -p "secret for $name: " secret || die "no secret typed"
  else
    secret=$(cat)
  fi
  [[ -n $secret ]] || die "empty secret: nothing written"
  # sops takes the plaintext as json whatever the record's shape is, and encrypts every value in it, so
  # sops takes the plaintext as json whatever the record's shape is, and encrypts every value in it, so
  # the one secret is exactly one field. The value travels in the environment, not in argv: a process's
  # arguments are readable by every user on the machine (/proc/PID/cmdline is 0444, environ is 0400),
  # and $ENV keeps a multi-line secret whole — measured byte-for-byte through both backends.
  json=$(CREDS_SECRET="$secret" jq -c -n '{secret:$ENV.CREDS_SECRET}')

  mkdir -p "$creds_dir"
  if [[ $ext == sops.* ]]; then
    printf '%s' "$json" |
      run_sops -e --input-type json --output-type "${ext#sops.}" --age "$recs" --config /dev/null /dev/stdin >"$target" ||
      {
        rm -f "$target"
        die "cannot encrypt $name" 3
      }
  else
    printf '%s' "$secret" | systemd-creds encrypt --user --name "$id" - "$target" ||
      die "systemd-creds encrypt failed for $name" 3
  fi
  chmod 400 "$target"
}

# The record a name resolves to, in REPLY: every name in decrypt and rm goes through here, so the name
# rule lives here too. A name must resolve to exactly one backend. REPLY rather than stdout keeps
# die() in this process instead of a subshell.
record_for() {
  local base cred sops_json sops_yaml want=''
  # A path is the record itself — the shape a unit, a pipeline, or `set FIELD FILE` passes — so it
  # resolves without the name rule.
  if [[ $1 == */* ]]; then
    [[ -e $1 ]] || die "no record: $1" 2
    [[ $1 == *.json || $1 == *.yaml || $1 == *.cred ]] ||
      die "no record: $1 — a record is *.cred, *.sops.json or *.sops.yaml" 2
    REPLY=$1
    return
  fi
  valid_name "$1" || die "invalid record name '$1'"
  base="$(base_name "$1")"
  cred="$creds_dir/$base.cred"
  sops_json="$creds_dir/$base.sops.json"
  sops_yaml="$creds_dir/$base.sops.yaml"
  # A suffix spelled on the name is an explicit request for that file, so it resolves even when
  # several exist — that is how the xilo wrapper asks for the fast backend. Without a suffix the name
  # is ambiguous: .cred wins, and a name that matches more than one file is refused, not guessed.
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
    [[ -e $f ]] && found+=("$f")
  done
  [[ ${#found[@]} -le 1 ]] ||
    die "more than one record for $base: ${found[*]##*/} — remove one, or name the backend you mean"
  REPLY=${found[0]:-}
  [[ -n $REPLY ]] || die "no record named '$1' in $creds_dir" 2
}

# Resolve every name before touching anything, so a name with no record removes nothing rather than
# half-clearing the list. -f covers a name repeated in one call; record_for already proved each file
# exists, so it cannot mask a real failure.
cmd_rm() {
  [[ $# -gt 0 ]] || die "rm needs at least one credential name"
  local targets=() name
  for name in "$@"; do
    record_for "$name"
    targets+=("$REPLY")
  done
  rm -f -- "${targets[@]}"
}

# Names or paths, then optionally `-- CMD ARGS...`. Without a command the secrets go to stdout (one
# record per line, or KEY=VALUE with --env). With a command they are never printed: they are exported
# into the environment of CMD, which replaces this process.
cmd_decrypt() {
  local env_format=0 names=() cmd=() assigns=() name base plain json assign key got
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

  # Backend choice is here and nowhere else: a .cred record is decrypted by systemd-creds under the
  # bare name it was encrypted under, and a sops record comes back as its whole json — one sops
  # process per record, whichever fields are asked for. The env key is the record's basename, so a
  # path and a name fill the same variable.
  # shortcut: buffered per record like encrypt, so a trailing newline is stripped — encrypt strips it
  # on write too, so no record carries one. Upgrade to a stream if a record must keep exact bytes.
  for name in "${names[@]}"; do
    base="$(base_name "${name##*/}")"
    [[ $env_format == 0 || $base =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      die "'$name' is not a usable environment variable name — --env takes a bare credential name (XILO, or XILO.sops.yaml)"
    record_for "$name"
    if [[ $REPLY == *.cred ]]; then
      plain=$(systemd-creds decrypt --user --name "$base" "$REPLY") || die "cannot decrypt $REPLY" 3
      assigns+=("$base=$plain")
      continue
    fi
    json=$(run_sops -d --output-type json "$REPLY") ||
      die "cannot decrypt $REPLY — sops needs a key: the identity file at \$SOPS_AGE_FILE, or \$SOPS_KEYS_CMD when there is none; a machine-local .cred record needs no key at all" 3
    if [[ $env_format == 0 ]]; then
      # Plain decrypt prints one secret and nothing else; a bundle has no single secret to print, so
      # the message names the form that can read it instead of reporting a key problem that is not the
      # cause.
      plain=$(printf '%s' "$json" | jq -r '.secret // empty') || die "cannot read $REPLY" 3
      [[ -n $plain ]] ||
        die "record '$name' has no 'secret' field — decrypt --env $name prints its fields as KEY=VALUE" 2
      assigns+=("$base=$plain")
      continue
    fi
    # A bundle's fields are environment variables. Assignments are read NUL-separated straight from
    # jq — a command substitution would drop the NULs, and split on newlines a multi-line secret would
    # arrive truncated. Only a non-empty string is a secret, matching what encrypt accepts; a key no
    # shell can expand is skipped rather than exported as a dead variable; a field named `secret` is
    # the record's own secret, so it takes the record's name.
    got=0
    while IFS= read -r -d '' assign; do
      key="${assign%%=*}"
      [[ $key == secret ]] && key="$base"
      [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      assigns+=("$key=${assign#*=}")
      got=1
    done < <(printf '%s' "$json" |
      jq -j 'to_entries[] | select(.value | type == "string" and length > 0) | "\(.key)=\(.value)\u0000"')
    [[ $got == 1 ]] || die "record '$name' holds no field a shell can name" 3
  done

  # With a command the secrets reach it through its environment only, never through stdout.
  [[ ${#cmd[@]} == 0 ]] || exec env -- "${assigns[@]}" "${cmd[@]}"
  for assign in "${assigns[@]}"; do
    [[ $env_format == 1 ]] && printf '%s\n' "$assign" || printf '%s\n' "${assign#*=}"
  done
}

# The plaintext is always json: jq, xilo and every unit parse it, whatever the record's shape.
cmd_decrypt_file() {
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
# so an argument is readable by every user for the life of the process. It comes from stdin — an
# anonymous pipe, no path to permission-check — or from a prompt with echo off. shortcut: buffered in
# a variable, which drops a trailing newline; upgrade to a stream if a value must keep exact bytes.
cmd_set() {
  [[ $# -eq 2 ]] || die "set needs FIELD FILE — the new value comes from stdin or a prompt, never an argument" 1
  need_field "$1"
  need_record "$2"
  local plain recs value
  plain=$(run_sops -d --output-type json "$2") || die "cannot decrypt $2" 3
  recs=$(meta_values "$2" | paste -sd, -)
  [[ -n $recs ]] || die "no recipients in $2" 3
  if [[ -t 0 ]]; then
    read -rs -p "new value for $1: " value || die "no value typed"
  else
    value=$(cat)
  fi
  [[ -n $value ]] || die "empty value: nothing written"
  # $ENV rather than --arg keeps the value out of jq's argv as well: an environment is mode 0400,
  # readable by your UID only.
  printf '%s' "$plain" | CREDS_SET_VALUE="$value" jq -c --arg k "$1" '.[$k] = $ENV.CREDS_SET_VALUE' |
    rewrite "$2" "${2##*.}" "$recs" ||
    die "cannot set $1 in $2" 3
}

# Recipient rotation: sops has no flag that changes recipients without a config file, so
# re-encrypting is the rekey.
cmd_rekey() {
  [[ $# -gt 0 ]] || die "rekey needs at least one record" 1
  local recs file
  recs="$(cmd_keys)" || exit 1
  for file in "$@"; do
    need_record "$file"
    run_sops -d --output-type json "$file" |
      rewrite "$file" "${file##*.}" "$recs" ||
      die "cannot rekey $file" 3
  done
}

cmd_recipients() {
  need_record "$1"
  meta_values "$1"
}

cmd_verify() {
  need_record "$1"
  run_sops -d --output-type json "$1" >/dev/null || die "cannot verify $1 — MAC or key failure" 3
}

# reset — the sops environment back to nothing, so init starts fresh. credsctl owns the identity, the
# rules file, the records, and a recipient file only if someone made one; only a .cred stays, because
# systemd-creds owns that, not sops. Removing the identity and the records is permanent (the identity
# is the only thing that can read them) and the rules file is the invite list for every other machine,
# so without --force this names the files and deletes nothing.
cmd_reset() {
  local force=0 files=() dir
  [[ -z ${1:-} || ${1:-} == --force ]] || die "reset takes --force or no argument" 1
  [[ ${1:-} == --force ]] && force=1
  # sops' own directory only when the identity really is sops' default file. A custom SOPS_AGE_FILE
  # points somewhere credsctl has no business deleting, so just that file goes.
  if [[ $identity == "$HOME/.config/sops/age/keys.txt" ]]; then
    [[ -d $HOME/.config/sops ]] && files+=("$HOME/.config/sops")
  elif [[ -e $identity ]]; then
    files+=("$identity")
  fi
  [[ -e $rules ]] && files+=("$rules")
  [[ -e $recipients ]] && files+=("$recipients")
  # The store the commands read, not the directory the rules file happens to sit in: CREDS_DIR can
  # point away from CREDS_ROOT, and resetting elsewhere would delete records nobody is using.
  dir="$creds_dir"
  shopt -s nullglob
  files+=("$dir"/*.sops.json "$dir"/*.sops.yaml)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    printf 'nothing to reset — no identity, no rules file, no record in %s\n' "$dir"
    return 0
  fi
  printf '%s\n' "${files[@]}"
  [[ $force == 1 ]] ||
    die "reset deletes encrypted records whose only key is the identity above, and the rules file that invites other machines: re-run with --force" 1
  rm -rf "${files[@]}"
  printf 'reset: %s removed — credsctl init now starts fresh\n' "${#files[@]}"
}

# A ~ only reaches us literal when it was quoted or came through a variable, so the path arguments are
# expanded here before any command sees them. get and set take a FIELD first, so for those only the
# trailing file argument expands — a value now comes from stdin, where tilde() never touches it.
first=2
case "${1:-}" in
get | set) first=3 ;;
esac
if [[ $# -ge 2 ]]; then
  args=("${@:1:first-1}")
  for ((i = first; i <= "$#"; i++)); do args+=("$(tilde "${!i}")"); done
  set -- "${args[@]}"
fi

# Every command is `cmd_<name>`; `keys` is cmd_keys with its arguments ignored. The name is taken
# before the shift, so the function still gets the arguments.
cmd_name=${1:-}
case $cmd_name in
list | encrypt | rm | remove | init | protected | keys | get | set | rekey | recipients | verify | reset)
  shift
  "cmd_$cmd_name" "$@"
  ;;
decrypt)
  shift
  # A lone path is the record itself: a sops record prints its whole json map, a .cred path prints its
  # secret exactly as its name would, and a file of no record shape is refused. Anything else is a list
  # of records — record_for resolves a path there too, so a path leading the list does not swallow the
  # records behind it.
  if [[ $# == 1 && ${1:-} == */* && ${1:-} != *.cred ]]; then cmd_decrypt_file "$1"; else cmd_decrypt "$@"; fi
  ;;
"" | -h | --help | help) usage ;;
*) die "unknown command '$cmd_name' — 'credsctl help' lists the commands" ;;
esac
