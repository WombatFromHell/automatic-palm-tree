#!/usr/bin/env bash
# The prompt gate both install.sh (ADR-ca72f792db52) and terraform.sh (ADR-b77ec913151f) share: one
# destructive step, one answer, and no terminal means nobody gave permission. Sourced, so the caller
# owns --dry-run/--force and therefore $dry and $force.
# shellcheck disable=SC2154

say() { printf '%s\n' "$*"; }

# Without a terminal the step is refused rather than assumed. --force / INSTALL_FORCE=1 is the only
# non-interactive override, and --dry-run runs nothing.
confirm() {
  if [ "$dry" = 1 ]; then
    say "[dry-run] $1"
    return 0
  fi
  if [ "$force" = 1 ]; then
    say "$1 (forced)"
    return 0
  fi
  if [ ! -t 0 ]; then
    say "refused: $1 needs a confirmation and there is no terminal (use --force or INSTALL_FORCE=1)"
    return 2
  fi
  printf 'confirm [y/N]: '
  read -r answer
  if [ "$answer" != "y" ]; then
    say "not confirmed: nothing done"
    return 2
  fi
}

run() {
  if [ "$dry" = 1 ]; then
    say "[dry-run] $*"
    return 0
  fi
  "$@"
}
