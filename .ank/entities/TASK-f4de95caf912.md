---
id: TASK-f4de95caf912
type: task
slug: sopsctl-init-says-what-a-legacy-ssh-identity-nee
title: sopsctl init says what a legacy ssh identity needs
created: 2026-11-04T17:01:48Z
author: josh@methyl-bazzite
status: done
scope:
  - features/hm-creds/sopsctl.sh
  - tests/sopsctl.bats
blocked_by: []
done_criteria: |
  sopsctl init --from-ssh <pre-2014 PEM keypair> exits 1 naming the format and the fix (ssh-keygen -o first) instead of ssh-to-age's conversion error, and tests/sopsctl.bats asserts that message plus that nothing is written.
criteria_by: creator
method: diagnose
proof:
  - type: commit
    ref: 3e24b81
    criteria: f678850989e6
    via: submitted
schema: 4
version: 2
---

sopsctl.sh:187: ssh_identity_protected probes the OpenSSH header only, so a legacy PEM key reads as
unprotected and ssh-to-age reports it cannot convert — the same exit path a bad keypair already
takes, which means the user is told their key is broken when it only needs reformatting.
