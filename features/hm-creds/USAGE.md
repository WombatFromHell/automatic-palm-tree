# hm-creds — using your credential records

Everything here is installed by the `hm-creds` feature: `credsctl`, `sopsctl`, and `sops`.

A record is one file holding exactly one secret, in `~/.local/share/credentials` (override with
`CREDS_DIR`). Every record is written `0400`, encrypt never overwrites, and plaintext only ever goes
to stdout — so pipe a secret, never redirect it onto disk.

The extension picks the backend:

| record | backend | who can read it | how the key arrives |
| --- | --- | --- | --- |
| `NAME.cred` | systemd-creds | this machine only (UID + machine-id) | nothing to fetch — silent |
| `NAME.sops.json` | sops + age, recipients in the record's metadata | whoever holds a listed age key | `sopsctl` runs `$SOPS_KEYS_CMD` (KWallet) — no key file, no terminal |
| `NAME.age` | age with `$CREDS_IDENTITY` | whoever holds a listed age key | age reads the identity passphrase from a terminal only |

`.cred` is what machine-local automation uses, because a systemd unit or an elevated `sudo` run can
decrypt it with no prompt. `.age` cannot: age will not take a passphrase from `ssh-agent` or
`SSH_ASKPASS`, so anything running without a terminal fails on it. `.sops.json` is the portable
record that avoids that — the key is fetched from the wallet by a command, so units, `sudo` runs and
`xilo-wrapped` pushes all work. `.age` still works today; it is being replaced by `.sops.json`.

## sopsctl

```bash
sopsctl init      # once: generate an age identity, store the secret in KWallet
                  # (folder flakeroot, entry creds-identity), append the public key to
                  # ~/.local/share/credentials/recipient. Idempotent.
sopsctl keys      # the recipient public keys you can encrypt to — never a secret key
```

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
and `ALPHA.age` are one record, and `--env` keys are the bare name.

`credsctl` delegates a `.sops.json` record to `sopsctl` once the migration lands; until then it only
reads `.cred` and `.age`.

## Overrides and exit codes

- `CREDS_DIR` / `CREDENTIALS_DIRECTORY` — where the store is.
- `SOPS_KEYS_CMD` — how a key is fetched. Default `kwallet-query -f flakeroot -r creds-identity
  kdewallet`; on a host without KWallet, point it at a command that prints an age secret key.
- `SOPS_RECIPIENTS` — the recipient file (default `~/.local/share/credentials/recipient`).
- `CREDS_IDENTITY` / `CREDS_RECIPIENTS` — the `.age` backend's identity and recipient file.

Both tools exit `0` ok, `1` bad usage, `2` no such record, `3` encrypt or decrypt failed.

## Do not

- `chmod 600` a record or `sops --set` one in place: `0400` forbids in-place writes, which is why
  `sopsctl set` and `rekey` rewrite through a temp file.
- `cat` a record expecting to read it — the ciphertext is opaque, `decrypt` is the read path.
- Copy a `.cred` to another machine: it is bound to this one and will not decrypt there. Use a
  `.sops.json` record for anything portable.
