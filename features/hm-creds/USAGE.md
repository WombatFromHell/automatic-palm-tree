# hm-creds — using your credential records

Everything here is installed by the `hm-creds` feature: `credsctl`, `sopsctl`, and `sops`.

A record is one file holding exactly one secret, in `~/.local/share/credentials` (override with
`CREDS_DIR`). Every record is written `0400`, encrypt never overwrites, and plaintext only ever goes
to stdout — so pipe a secret, never redirect it onto disk.

The extension picks the backend:

| record | backend | who can read it | how the key arrives |
| --- | --- | --- | --- |
| `NAME.cred` | systemd-creds | this machine only (UID + machine-id) | nothing to fetch — silent |
| `NAME.sops.json` | sops + age, recipients in the record's metadata | whoever holds a listed age key | an age identity file, read by sops itself — no prompt, no terminal |

`.cred` is what machine-local automation uses, because a systemd unit or an elevated `sudo` run can
decrypt it with no prompt. The portable record that avoids a prompt is `.sops.json`: the key is
the key lives in a file sops reads by itself, so units, `sudo` runs and shell prompts all work.

Records written before this commit carry the `.age` extension and are invisible to `credsctl` until
the migration re-encrypts them as `.sops.json`.

## sopsctl

```bash
sopsctl init      # once: write an age identity to ~/.config/sops/age/keys.txt (0600, sops' own
                  # lookup path), add its public key to ~/.local/share/credentials/recipient and
                  # to a .sops.yaml of creation rules beside the records. Idempotent. Nothing
                  # prompts, and init prints the paths plus the next command.
sopsctl keys      # the recipient public keys you can encrypt to — never a secret key
```

Key by your ssh identity instead, so one passphrase protects both sides:

```bash
sopsctl protected ~/.ssh/flakeroot_ed25519          # 0 means it needs a passphrase to read
sopsctl init --from-ssh ~/.ssh/flakeroot_ed25519    # derive the age keypair with ssh-to-age
sopsctl rekey ~/.local/share/credentials/*.sops.json # give existing records the new recipient
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
Once that public key is in the recipient file, `sopsctl keys` prints it, and because sops finds the
derived identity file itself, decrypting any record needs no prompt and no key flag.

Add a secret:

```bash
jq -n --arg t "$(passphrase-or-token)" '{token:$t}' |
  sopsctl encrypt > ~/.local/share/credentials/GH_TOKEN.sops.json
chmod 400 ~/.local/share/credentials/GH_TOKEN.sops.json
sopsctl verify ~/.local/share/credentials/GH_TOKEN.sops.json
```

`encrypt` takes JSON on stdin and writes ciphertext on stdout; you name the file and set its mode.
A field whose name ends in `_unencrypted` stays readable in the file — that is the only way to keep
a field in plain text.

Read a secret:

```bash
sopsctl get token ~/.local/share/credentials/GH_TOKEN.sops.json    # one field
sopsctl decrypt ~/.local/share/credentials/GH_TOKEN.sops.json      # the whole map
GH_TOKEN="$(sopsctl get token ~/.local/share/credentials/GH_TOKEN.sops.json)" cmd   # into a program's environment
```

Change one value — it decrypts, edits that field, re-encrypts to the recipients already in the
record, replaces the file, and leaves it `0400`:

```bash
sopsctl set token "ghp_new..." ~/.local/share/credentials/GH_TOKEN.sops.json
```

Rotate who can read the store:

```bash
printf 'age1newpubkey...\n' >> ~/.local/share/credentials/recipient
sopsctl rekey ~/.local/share/credentials/*.sops.json
```

`rekey` re-encrypts each record listed to the current recipient file. To drop someone, delete their
line and rekey.

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
credsctl rm ALPHA                 # records are immutable: a change is rm, then encrypt again
```

Quote the `--env` command (`sh -c '...'`) or read it with `printenv` — your shell expands `$ALPHA`
before `credsctl` runs. Note that a name doubles as a systemd credential ID: `ALPHA`, `ALPHA.cred`
and `ALPHA.sops.json` are one record, and `--env` keys are the bare name.

`credsctl` delegates a `.sops.json` record to `sopsctl`: every sops flag, the recipient file and the
key command belong to `sopsctl`.

## Overrides and exit codes

- `CREDS_DIR` / `CREDENTIALS_DIRECTORY` — where the store is.
- `SOPS_AGE_FILE` — the age identity (default `~/.config/sops/age/keys.txt`, where sops looks by
  itself). Move it there only if you want the file store somewhere else; while a readable identity
  exists, it is what decrypt uses and no key command runs.
- `SOPS_RULES` — the `.sops.yaml` of creation rules for new records (default `.sops.yaml` beside the
  recipient file). Public keys only, so it is safe to commit; sops reads it from the **current
  directory**, which is why `init` prints the directory to `cd` into.
- `SOPS_KEYS_CMD` — the wallet route, used only when no identity file is readable. Default
  `kwallet-query -f flakeroot -r creds-identity kdewallet`; point it at any command that prints an
  age secret key.
- `SOPS_RECIPIENTS` — the recipient file (default `~/.local/share/credentials/recipient`).

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
