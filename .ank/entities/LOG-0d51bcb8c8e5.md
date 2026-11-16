---
id: LOG-0d51bcb8c8e5
type: log
title: "measured: cmd_keys with SOPS_RECIPIENTS pointed at a sealed record returns 'age1uw2…' (metadata"
created: 2026-11-16T03:35:05Z
author: josh@methyl-bazzite
scope:
  - features/hm-creds/credsctl.sh
  - tests/creds.bats
about: TASK-499279ef8551
seq: 3
schema: 4
version: 1
---

 key) and never ciphertext — sops writes ENC[AGE1,…] uppercase, age_keys' pattern is lowercase age1[a-z0-9]+, so encrypted lines cannot match. Real-sops repro after the fix: recipients lists exactly the key in json and yaml; set recipient FILE exit 0 in both.
