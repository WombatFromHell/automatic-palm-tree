---
id: TASK-1938ef4cbb51
type: task
slug: the-red-guard-rule-names-the-expect-marker-it-ac
title: The red-guard rule names the expect marker it actually parses
created: 2026-11-04T17:18:56Z
author: josh@methyl-bazzite
status: closed
scope:
  - tests/run.sh
blocked_by: []
done_criteria: |
  an amending ADR of ADR-5eb78b01a869 states the literal "# expect: <substring>" in its constraint, and `bash tests/run.sh` still prints ok red guards (13 files) with tests/red/*.nix and tests/run.sh unchanged.
criteria_by: creator
schema: 4
version: 3
---

ADR-5eb78b01a869 now reads "whose first line is ,": the "# expect: <substring>" literal was
dropped on creation. The code still holds it - all 13 guards in tests/red/*.nix carry the
comment and tests/run.sh parses it off line 1 - so the rule no longer states the contract the
gate enforces, and a contributor could ship a guard without the marker and pass.

The repair is a proposed amending ADR, not an edit: the constraint and scope are anchored by
the ratification commit, and the agent role cannot accept or edit-constraint. No code change.
