#!/usr/bin/env bash
# Format every file the flake ships, then lint it. fd respects .gitignore, so the tree that gets
# rewritten is the tree the flake evaluates. Ships as apps.<system>.style; run it from the flake
# directory.
# -r means no files invokes nothing: with zero arguments alejandra, shfmt and shellcheck read
# stdin and block.
set -euo pipefail

fd -g '*.nix' -0 | xargs -0 -r alejandra -q
statix check

fd -g '*.{sh,bats,bash}' -0 | xargs -0 -r shfmt -w -s -i 2
# bats assigns its variables in setup()/teardown(), which shellcheck's dataflow analysis treats as
# a subshell that never ran: every one reads as unset (SC2154) or as a modification that is lost
# (SC2030, SC2031). Those three are false positives in bats, so only the bats pass drops them --
# plain .sh keeps the full checks, and everything else bats raises is fixed in the file.
# -x follows `source` lines, so a `# shellcheck source=` directive resolves instead of reading as
# SC1091. *.bash is included on both passes: tests/vm-lib.bash is sourced by shipped scripts and was
# previously neither formatted nor linted.
fd -g '*.bats' -0 | xargs -0 -r shellcheck -x --exclude=SC2154,SC2030,SC2031
fd -g '*.sh' -0 | xargs -0 -r shellcheck -x
# A *.bash file is sourced, never run: the variables it declares belong to whoever sources it
# (SC2034), and helpers.bash reads bats' `output`/`status`, which only exist inside a bats run
# (SC2154).
fd -g '*.bash' -0 | xargs -0 -r shellcheck -x --exclude=SC2034,SC2154

# Markdown through oxfmt: it picks its own files and honours .gitignore, so no fd/xargs here, and
# it needs no config file -- defaults are the house style. .ank/ is dropped by a positional exclude
# rather than an ignore file, because it is ank's content-addressed corpus: oxfmt would rewrite its
# emphasis and its YAML front matter.
# --no-error-on-unmatched-pattern means a tree with no markdown invokes nothing.
oxfmt --no-error-on-unmatched-pattern '!.ank/'
