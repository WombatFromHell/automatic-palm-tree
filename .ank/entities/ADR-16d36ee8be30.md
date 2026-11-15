---
id: ADR-16d36ee8be30
type: adr
slug: credsctl-init-from-ssh-gets-ssh-to-age-s-passphr
title: credsctl init --from-ssh gets ssh-to-age's passphrase from one place
created: 2026-11-15T19:47:15Z
author: josh@methyl-bazzite
status: accepted
scope:
  - features/hm-creds/credsctl.sh
  - features/hm-creds/home.nix
  - tests/creds-sops.bats
constraint: |
  The passphrase of a protected ssh origin reaches ssh-to-age only through a terminal read with echo off or SSH_TO_AGE_PASSPHRASE, and no askpass helper may be wired into this path, because ssh-to-age is not ssh and never reads SSH_ASKPASS.
enforced_by:
  - features/hm-creds/credsctl.sh#cmd_derive_from_ssh
  - features/hm-creds/credsctl.sh#read_origin_passphrase
supersedes: ADR-37641b841415
ratified: 50e0c975fe70
anchor: bd37237d4b38affe08154cccfec83c03d36a494a
verified:
  - by: josh@methyl-bazzite
    at: 2026-11-15T19:47:29Z
schema: 4
version: 2
---

`credsctl init --from-ssh` is the whole bridge, and `sopsctl` is gone (ADR-9b1a7ca36f40), so this rule
is republished under that name: it needs both halves (`<keypair>` and `<keypair>.pub`, checked before
anything is converted), takes the public half through `ssh-to-age -i` for the recipients and the
private half through `ssh-to-age -private-key`, and asks for the passphrase *before* anything is
written, so a run that cannot get one leaves no temp file and no half-written identity. ssh-to-age's
own call runs `</dev/null` so it cannot reach a terminal behind the script's back. A blank read is
refused.

A rerun on the same identity is recognised by the `# created: ssh-to-age from ...` line; deriving over
an identity holding a different keypair is refused, because records sealed to the old recipient would
stop opening. That is a rotation (`init` without `--from-ssh`, then `recipients` and `rekey`), not a
rewrite. Nothing here copies, unlocks or rewrites the ssh files, and the keypair stays 0600.

This supersedes ADR-37641b841415, whose body still names `sopsctl init --from-ssh`. The constraint is
unchanged; only the command moved.
