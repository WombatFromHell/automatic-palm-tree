# hm-creds — using your credential records

Everything here is installed by the `hm-creds` feature: `credsctl`, `sopsctl`, and `sops`.

A record is one file in `~/.local/share/credentials` (override with `CREDS_DIR`), alongside the
`.sops.yaml` of creation rules that names who may read a new record. A `.cred` holds exactly one
secret; a `.sops.json` / `.sops.yaml` record is a json map, so it can hold several secrets named by
their fields. A `recipient` file you made yourself — one age public key per line — joins those rules;
nothing writes
it. Two roots move the whole environment for a store that lives elsewhere: `AGE_ROOT` for the
identity directory (`$AGE_ROOT/age/keys.txt`, default `~/.config/sops`, e.g.
`AGE_ROOT=/var/lib/sops-nix`) and `CREDS_ROOT` for the rules, records and recipient file (default
`~/.local/share/credentials`, e.g. `CREDS_ROOT=./secrets`). Every record ends up `0400`: encrypting a
file turns its plaintext into ciphertext in place, and encrypting a stream writes ciphertext to
stdout only.

The extension picks the backend:

| record                              | backend                                         | who can read it                      | how the key arrives                                                |
| ----------------------------------- | ----------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------ |
| `NAME.cred`                         | systemd-creds                                   | this machine only (UID + machine-id) | nothing to fetch — silent                                          |
| `NAME.sops.json` / `NAME.sops.yaml` | sops + age, recipients in the record's metadata | whoever holds a listed age key       | an age identity file, read by sops itself — no prompt, no terminal |

`.cred` is what machine-local automation uses, because a systemd unit or an elevated `sudo` run can
decrypt it with no prompt. The portable record that avoids a prompt is `.sops.json`: the key lives in a
file sops reads by itself, so units, `sudo` runs and shell prompts all work.

## sopsctl

```bash
sopsctl init      # once: write an age identity to ~/.config/sops/age/keys.txt (0600, sops' own
                  # lookup path) and its public key into a .sops.yaml of creation rules beside the
                  # records. Idempotent. Nothing prompts, and init prints the paths plus the next
                  # command.
sopsctl keys      # the recipient public keys you can encrypt to — never a secret key
sopsctl reset     # name the files sopsctl owns — the identity, the rules file, a recipient file if
                  # you made one, and every *.sops.json / *.sops.yaml record — and delete nothing.
                  # `reset --force` deletes them so init starts fresh. That is unrecoverable: the
                  # identity is the only thing that can read the records, and the rules file is the
                  # invite list for every other machine that holds one. Only *.cred stays — systemd-creds owns
                  # those, not sops. Re-add each machine's public key afterwards, then `rekey`.
```

Key by your ssh identity instead, so one passphrase protects both sides:

```bash
sopsctl protected ~/.ssh/flakeroot_ed25519          # 0 means it needs a passphrase to read
sopsctl init --from-ssh ~/.ssh/flakeroot_ed25519    # derive the age keypair with ssh-to-age
sopsctl rekey ~/.local/share/credentials/*.sops.json ~/.local/share/credentials/*.sops.yaml \
  # give existing records the new recipient; the rules file `.sops.yaml` is not a record, so name the two shapes
```

`--from-ssh` takes the **private** key path — no `.pub` on the argument you pass. It reads
`<keypair>.pub` for the age public key and the private key, once, through `ssh-to-age`: a protected
origin is asked for its passphrase first (echo off), before anything is converted or written, and that
passphrase travels to ssh-to-age in `SSH_TO_AGE_PASSPHRASE` — the release nixpkgs ships (ssh-to-age
1.2.0) has no other passphrase input and the command runs with no terminal of its own. A caller with
no terminal (a unit, a script, a GUI launcher) exports the variable and the prompt is skipped; with
neither the prompt fails and the message says what to export. Nothing here
copies, unlocks or rewrites the ssh keypair, so ssh keeps working and its passphrase still applies.
No askpass helper ships with `sopsctl` and none belongs on this path: ssh-to-age is not ssh, it never
reads `SSH_ASKPASS`, so such a helper could only be called by hand —
`SSH_TO_AGE_PASSPHRASE="$(ksshaskpass "Enter passphrase for <keypair>: ")" sopsctl init --from-ssh <keypair>`
is how to get a KDE dialog when one is wanted, and on this host ksshaskpass cannot run at all: its
config file `~/.config/ksshaskpassrc` is not writable, so every attempt raises its error dialog, prints
the fontconfig warnings Qt brings up, and exits non-zero. That flood is ksshaskpass, not `sopsctl`.
The identity file it writes is the **disposable** half: it is regenerable with the same command, while
the ssh keypair is the origin. A rerun with the same keypair is a no-op.
Once that public key is in the rules file, `sopsctl keys` prints it, and because sops finds the
derived identity file itself, decrypting any record needs no prompt and no key flag.

Add a secret — write the plaintext where the record will live, then encrypt it in place:

```bash
printf 'token: "%s"\nhost_unencrypted: github\n' "$(passphrase-or-token)" \
  > ~/.local/share/credentials/GH_TOKEN.sops.yaml
chmod 600 ~/.local/share/credentials/GH_TOKEN.sops.yaml
sopsctl encrypt ~/.local/share/credentials/GH_TOKEN.sops.yaml   # recipients from ~/.local/share/credentials/.sops.yaml
sopsctl verify ~/.local/share/credentials/GH_TOKEN.sops.yaml
```

`encrypt FILE` takes a plaintext `*.sops.yaml` or `*.sops.json` file — the suffix is its shape —
encrypts it in place with the recipients from that rules file, which it names with `--config` so the
current directory never decides who can read the record, and leaves the file `0400`. The plaintext is
gone once sops has written the ciphertext. A file that already carries sops metadata is a record, and
a record is immutable: `encrypt` refuses it, so a change is `set`, `rekey`, or `rm` and encrypt again.

With no file, `encrypt` reads JSON on stdin and writes ciphertext to stdout, which is what `credsctl`
and a pipe use; `--format json|yaml` picks the shape, yaml by default, and the recipients come from
the rules file — plus a `recipient` file if you made one — because a `path_regex` can never match a
stream. A field whose name ends in `_unencrypted`
stays readable in the file — that is the only way to keep a field in plain text.

Read a secret:

```bash
sopsctl get token ~/.local/share/credentials/GH_TOKEN.sops.json    # one field
sopsctl decrypt ~/.local/share/credentials/GH_TOKEN.sops.json      # the whole map
GH_TOKEN="$(sopsctl get token ~/.local/share/credentials/GH_TOKEN.sops.json)" cmd   # into a program's environment
```

Change one value — it decrypts, edits that field, re-encrypts to the recipients already in the
record, replaces the file, and leaves it `0400`. The new value comes from stdin, or from a prompt
with echo off when you are at a terminal; it is never an argument, because `/proc/PID/cmdline` is
world-readable and an argument also lands in your shell history:

```bash
sopsctl set token ~/.local/share/credentials/GH_TOKEN.sops.json   # type it at the prompt
printf '%s' "$token" | sopsctl set token ~/.local/share/credentials/GH_TOKEN.sops.json   # scripted
```

Rotate who can read the store:

```bash
printf 'age1newpubkey...\n' >> ~/.local/share/credentials/recipient
sopsctl rekey ~/.local/share/credentials/*.sops.json ~/.local/share/credentials/*.sops.yaml
```

`rekey` re-encrypts each record listed to the current recipients — the rules file, plus a `recipient`
file if you made one (adding the key to the `keys:` block of `.sops.yaml` works too). To drop someone,
delete their line and rekey.

Audit and integrity:

```bash
sopsctl recipients ~/.local/share/credentials/XILO.sops.json  # who holds this record
sopsctl verify   ~/.local/share/credentials/XILO.sops.json    # exit 0 means the MAC is intact
```

`verify` decrypts to `/dev/null` and prints nothing, so it is what scripts gate on; a tampered
record exits 3.

There is no interactive editor command — `sops -e FILE` needs a key file. Multi-field rewrites go
through `decrypt | jq ... | encrypt > file`.

## credsctl

```bash
credsctl list                     # every record in the store
credsctl encrypt ALPHA            # prompts on a terminal (echo off, one line); pipe or pass FILE for multi-line
credsctl encrypt ALPHA /path/file # encrypt a file instead of stdin
credsctl decrypt ALPHA B          # print the secrets, one record per line
credsctl decrypt --env ALPHA -- sh -c 'printenv ALPHA'   # run a command with the secrets in its environment
credsctl encrypt XILO.sops.json --fields fields.json    # several secrets in one record, their field names being the variables
credsctl encrypt XILO.sops.yaml --fields fields.json    # the same record in sops' yaml shape
credsctl decrypt --env XILO       # every field of that record as KEY=VALUE
credsctl rm ALPHA                 # records are immutable: a change is rm, then encrypt again
```

Quote the `--env` command (`sh -c '...'`) or read it with `printenv` — your shell expands `$ALPHA`
before `credsctl` runs. Note that a name doubles as a systemd credential ID: `ALPHA`, `ALPHA.cred`,
`ALPHA.sops.json` and `ALPHA.sops.yaml` are one record, and `--env` keys are the bare name.

`--env` takes **names, never paths**: the name is the variable, and `credsctl` resolves it inside
`CREDS_DIR`. A spelled suffix is still a name (`--env ALPHA.sops.yaml` asks for that backend); a
path is `sopsctl`'s argument, not this one — `sopsctl get FIELD FILE` / `sopsctl decrypt FILE`.

A `.sops.json` record is a json map, so one record can hold several secrets — `--fields` takes the
object piped or as FILE (typed at a terminal it would be echoed), its keys being names a shell can
expand and its values non-empty strings. `credsctl` decrypts the record once and reads every field
from that plaintext, so a bundle fills a whole set in ~23ms; a `.cred` record costs ~1.2s per
decrypt, so several secrets there means several slow decrypts. Multi-line values are stored as
escapes and come back as real newlines. Plain `decrypt` on a bundle has no single secret to print:
it exits 2 and points at `--env`.

Either sops shape is the same record and the same fields. `.sops.yaml` is the shape sops itself prints
and the one you can hand-write; `credsctl` still reads it as json, because `sops -d --output-type json`
normalizes any record. The suffix decides only what gets written to disk.

`credsctl` delegates a `.sops.json` or `.sops.yaml` record to `sopsctl`: every sops flag, the
recipients and the key command belong to `sopsctl`.

## Overrides and exit codes

- `CREDS_DIR` / `CREDENTIALS_DIRECTORY` — where the store is.
- `AGE_ROOT` — the directory the identity lives in, in sops' own layout (`$AGE_ROOT/age/keys.txt`,
  default `~/.config/sops`). `AGE_ROOT=/var/lib/sops-nix` points at a sops-nix enclave.
- `CREDS_ROOT` — the directory the public half lives in: rules file, records, and a recipient file
  only if you made one (default `~/.local/share/credentials`). `CREDS_ROOT=./secrets` is the store a
  flake deploys; `credsctl` follows the same root.
- `SOPS_AGE_FILE` — the age identity (default `~/.config/sops/age/keys.txt`, where sops looks by
  itself). Move it there only if you want the file store somewhere else; while a readable identity
  exists, it is what decrypt uses and no key command runs.
- `SOPS_RULES` — the `.sops.yaml` of creation rules for new records (default `.sops.yaml` beside the
  records). Public keys only, so it is safe to commit; `sopsctl encrypt FILE` names it with
  `--config`, so the directory you sit in never matters — raw `sops -e FILE` reads it from the
  **current** directory, which is why `init` prints the directory to `cd` into.
- `SOPS_KEYS_CMD` — the wallet route, used only when no identity file is readable. Default
  `kwallet-query -f flakeroot -r creds-identity kdewallet`; point it at any command that prints an
  age secret key.
- `SOPS_RECIPIENTS` — an **optional** recipient file, one age public key per line, whose keys join the
  rules (default `~/.local/share/credentials/recipient`). Nothing creates or rewrites it; if you made
  one, `keys`, `encrypt` and `rekey` read it, and `reset` deletes it when it exists.

Both tools exit `0` ok, `1` bad usage, `2` no such record, `3` encrypt or decrypt failed.

## Do not

- `chmod 600` a record or `sops --set` one in place: `0400` forbids in-place writes, which is why
  `sopsctl set` and `rekey` rewrite through a temp file.
- `cat` a record expecting to read it — the ciphertext is opaque, `decrypt` is the read path.
- Copy a `.cred` to another machine: it is bound to this one and will not decrypt there. Use a
  `.sops.json` record for anything portable.
- Expect a hand-made record to pick up your key from `~/.local/share/credentials/.sops.yaml` while
  you sit somewhere else: sops reads creation rules from the current directory, so `cd` there (or
  pass `--age`).
- `git add` an age identity: the secret half belongs in `~/.config/sops/age/keys.txt`, never in the
  repo.
- Unlock, copy or re-encrypt an ssh identity to make sops convenient: `sopsctl init --from-ssh` reads
  it once and hands its passphrase to ssh-to-age in the environment, never to a file, and an origin
  key sitting unlocked in a shared directory is a worse secret than the age file.
