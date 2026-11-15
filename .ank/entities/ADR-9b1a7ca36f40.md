---
id: ADR-9b1a7ca36f40
type: adr
slug: one-credsctl-carries-both-credential-backends-an
title: One credsctl carries both credential backends, and encrypt seals a plaintext record file in place
created: 2026-11-15T17:18:35Z
author: josh@methyl-bazzite
status: accepted
scope:
  - features/hm-creds/credsctl.sh
  - features/hm-creds/home.nix
  - tests/creds.bats
  - tests/creds-sops.bats
constraint: |
  One credsctl carries both credential backends — a record suffix picks it (*.sops.json / *.sops.yaml is sops, .cred is the machine-bound fallback), a path argument seals that plaintext record file in place and a bare name streams one secret, sopsctl no longer exists, and the exit codes stay 1 usage / 2 no such record / 3 encrypt or decrypt failed.
amends: [ADR-68b53c992566]
ratified: 2264fdd01c7d
anchor: 7b51ce2d35080ac7b24d14e844f31ffd8fb6b899
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-15T17:22:47Z
schema: 4
version: 2
---

`sopsctl` is deleted; every sops detail lives in `credsctl.sh`, which is one package with
`jq sops age ssh-to-age` as runtime inputs. The delegation through PATH was the only thing that made
two binaries necessary, and `xilo` and `njust` still call `credsctl list|encrypt|decrypt|decrypt --env|rm`.

The encrypt surface is now file-driven, which is sops' own way:
- `credsctl encrypt ./NAME.sops.yaml` (or `.sops.json`) seals that plaintext file in place with
  `sops -e -i`, one process per file, then restamps it `0400` — sops writes `644`. A path of the wrong
  shape is a usage error (1); a record-shaped path that is not there is `no record` (2). sops refuses a
  file that already holds its metadata (exit 203), so credsctl keeps no guard of its own.
- `credsctl encrypt NAME` reads one secret from a secure prompt or a pipe and writes `NAME.cred` by
  default. A suffix on the name makes it a sops record instead: the plaintext credsctl builds is json,
  so the stream route passes `--input-type json --output-type <shape>` (measured on sops 3.13.3, json
  in / yaml out writes a yaml record; `--config /dev/null` is required because no path matches stdin).
- Recipients come from the rules file beside the store (`CREDS_ROOT/.sops.yaml`), plus the optional
  `SOPS_RECIPIENTS` file; an unresolvable sops-shaped name is a hard error naming `credsctl init`, never
  a silent `.cred` fallback. Recipients are resolved before the secret is asked for, so a run that
  cannot seal never leaves a person typing into a prompt about to fail.

Deleted with the merge: `--fields`, `--format`, `record_format`, the tty message, `credsctl sops`, and a
`-b` flag — the suffix already says which backend a record belongs to, and detection belongs at creation
only. `SSH_TO_AGE_PASSPHRASE`, the `</dev/null` guard, `meta_values`, `rules_from_keys`, and `reset`'s
`--force` guard are kept; ADR-37641b841415 and ADR-68b53c992566 still bind them.
