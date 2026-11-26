---
id: LOG-5ef7868cba98
type: log
title: "measured with real sops + a jq shim recording argv: pristine 'jq -c -n --arg v line one <newline>"
created: 2026-11-16T03:28:16Z
author: josh@methyl-bazzite
scope:
  - features/hm-creds/credsctl.sh
  - tests/creds.bats
about: TASK-d8b44c36354f
seq: 1
schema: 4
version: 1
---

 line two {secret:$v}' (secret in world-readable cmdline); fixed 'jq -c -n {secret:$ENV.CREDS_SECRET}', shim reports no secret byte in argv, multi-line secret round-trips byte-for-byte. Suites 149 ok (was 146).
