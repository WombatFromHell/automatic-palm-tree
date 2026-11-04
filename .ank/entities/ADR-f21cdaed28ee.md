---
id: ADR-f21cdaed28ee
type: adr
slug: shipped-shell-is-linted-whether-or-not-writeshel
title: Shipped shell is linted, whether or not writeShellApplication wraps it
created: 2026-11-04T21:29:33Z
author: josh@methyl-bazzite
status: proposed
scope:
  - features/*/*.sh
  - features/*/home.nix
  - features/*/nixos.nix
  - tests/*.bats
  - tests/shellwrap.nix
  - tests/run.sh
constraint: |
  A shipped shell helper is shellchecked before it ships - pkgs.writeShellApplication's checkPhase covers the wrapped ones, including text passed to it from a module, and tests/run.sh lints the unwrapped files directly - delivery may use pkgs.writeShellApplication or pkgs.writeShellScriptBin where runtimeInputs would pull the session's own tools into the closure, and a helper that does real work is also tested in tests/<tool>.bats against PATH stubs.
supersedes: ADR-3d145b52bf25
schema: 4
version: 1
---

Retires ADR-3d145b52bf25, whose demand that every helper be a .sh file delivered by writeShellApplication plus builtins.readFile still binds, and whose "behaviour never lives inline in a Nix module" still binds against shell that ships from modules. Its amendment ADR-5145c0c33c29 stays accepted and states this rule correctly; this entity carries the same rule, with the scope widened to features/*/*.sh (the old features/*.sh glob matched no tracked file) and features/*/nixos.nix added, so the superseded wording stops binding. --supersedes names one document, and edit cannot repoint it, so the pair cannot be retired by a single entity; retiring the amendment too would add a second binding copy of the same rule.

Measured: writeShellApplication wraps features/hm-creds/credsctl.sh and sopsctl.sh, features/hm-xilo/xilo.sh, the njust runner (features/hm-njust/home.nix:19, which execs ./nix.just beside the module), the inline oomd notify daemon (features/nixos-oom/nixos.nix:70) and the inline zswap prepare script (features/nixos-zswap/nixos.nix:23) - nixpkgs' checkPhase shellchecks all of them. pinentry-tmux.sh, pinentry-zellij.sh (features/hm-gpg/home.nix:6,14) and nasmount-sshfs.sh (features/hm-nasmount/home.nix:8) are delivered by pkgs.writeShellScriptBin deliberately: runtimeInputs rewrites PATH inside the script and would pull tmux, zellij and sshfs into the hm-gpg and hm-nasmount closures that the interactive session supplies today. tests/run.sh:43-46 lints the six unwrapped files with shellcheck -f gcc and fails the gate on any finding; tests/shellwrap.nix still asserts runtimeInputs and the substituted marker for the wrapped ones, facts shellcheck cannot see. helpers with real behaviour have bats suites (tests/njust.bats, tests/creds.bats, tests/xilo.bats).

Scope change carried forward: the old scope's `features/*.sh` glob matched no tracked file; `features/*/*.sh` is the shape that does, and features/*/nixos.nix is added because that is where inline module shell lives.

Known gap kept on purpose: inline text passed to writeShellScriptBin - hm-gpg's pinentry-fallback, features/hm-gpg/home.nix:23 - is not linted by the direct pass. Closing it means routing that text through a wrapper the gate builds, which changes the closure the session supplies.
