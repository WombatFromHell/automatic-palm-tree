---
id: LOG-6eead57ef924
type: log
title: bareEval takes three args (stubs, attrs, specialArgs) and the module under test has to sit in the
created: 2026-11-05T02:39:54Z
author: nix-unit-suite
scope:
  - tests/support.nix
  - tests/caches.nix
  - tests/warnings.nix
  - tests/home.nix
  - tests/wrap.nix
  - tests/filesystems.nix
about: TASK-40d9c6b2cc7c
seq: 1
schema: 4
version: 1
---

 stubs list, not beside it - caches.nix reads flakeCache only when ../modules/caches.nix is in the list. Adjacent attrset args parse only when each one is brace-balanced: two parens lost in filesystems.nix during the factory collapse, caught by nixf before the gate ran. Assertion counts verified unchanged (18/8/6/18/15); gate exit 0; style app clean.
