---
id: TASK-7dbeef325deb
type: task
slug: gate-shellchecks-shipped-shell-that-writeshellap
title: Gate shellchecks shipped shell that writeShellApplication does not wrap
created: 2026-11-04T17:18:56Z
author: josh@methyl-bazzite
status: closed
scope:
  - tests/run.sh
  - features/hm-gpg/pinentry-tmux.sh
  - features/hm-gpg/pinentry-zellij.sh
  - features/hm-nasmount/nasmount-sshfs.sh
  - lib/updater.sh
  - bootstrap.sh
  - update-all.sh
blocked_by: []
done_criteria: |
  `bash tests/run.sh` runs a shellcheck pass over pinentry-tmux.sh, pinentry-zellij.sh, nasmount-sshfs.sh, lib/updater.sh, bootstrap.sh and update-all.sh, prints an ok shellcheck line naming the file count, and exits non-zero when any one of them carries a finding, proven by planting x=$(y) in a temporary copy and watching that line FAIL.
criteria_by: creator
method: tdd
schema: 4
version: 2
---

writeShellApplication's checkPhase lint-checks the helpers it wraps, and shellwrap.nix asserts
their runtimeInputs and substituted markers. Nothing covers the shell that ships through
writeShellScriptBin (pinentry-tmux.sh, pinentry-zellij.sh, nasmount-sshfs.sh) or the loose
scripts (lib/updater.sh, bootstrap.sh, update-all.sh), so a lint error there reaches a host
without ever failing the gate. Measured today: all six report zero findings with
shellcheck -f gcc, so this adds coverage, not a rewrite.

Red first: a planted finding must fail the gate before the pass is trusted.
No helper is converted to writeShellApplication: runtimeInputs would pull tmux, zellij and
sshfs into the hm-gpg and hm-nasmount closures that the session supplies today.
