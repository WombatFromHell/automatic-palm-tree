#!/usr/bin/env bash
# update-all.sh — flake-wide pin updater
#
# Finds all features/*/update.sh scripts, runs each (aborts on first failure),
# then (with --flake) runs `nix flake update` to refresh flake.lock.
#
# All args except --flake are forwarded to each feature updater, so e.g.
# `./update-all.sh --check` runs every feature in check mode.
#
# Usage:
#   ./update-all.sh            # run all feature updaters
#   ./update-all.sh --flake    # also run `nix flake update`
#   ./update-all.sh --check    # check all features (exit 1 if any needs updating)

set -euo pipefail

FLAKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$FLAKE_ROOT"

FLAKE_UPDATE=false
args=()
for a in "$@"; do
  case "$a" in
    --flake) FLAKE_UPDATE=true ;;
    *) args+=("$a") ;;
  esac
done

count=0
while IFS= read -r script; do
  count=$((count + 1))
  echo "==> Running $script${args:+: ${args[*]}}" >&2
  "$script" "${args[@]}"
done < <(find features \( -type f -o -type l \) -name update.sh | sort)

if [[ $count -eq 0 ]]; then
  echo "==> No update.sh scripts found under features/" >&2
fi

if $FLAKE_UPDATE; then
  echo "==> Running nix flake update..." >&2
  nix flake update
fi

# --- Commit -----------------------------------------------------------------

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "==> Not a git work tree; skipping commit." >&2
  exit 0
fi

git add features flake.lock

# Don't commit on top of unrelated work-in-progress.
DIRTY_FILES=$(git status --porcelain | sed 's/^.. //')
if [[ -n "$(printf '%s\n' "$DIRTY_FILES" | grep -vE '^(features/|flake\.lock$|update-all\.sh$)' || true)" ]]; then
  echo "==> Repo is dirty beyond features/ and flake.lock; skipping commit." >&2
  exit 0
fi

if git diff --cached --quiet; then
  echo "==> Nothing to commit." >&2
  exit 0
fi

LOCK_HASH=$(sha256sum flake.lock | cut -c1-8)
git commit -m "chore: update packages and flake.lock #${LOCK_HASH}"
echo "==> Committed: chore: update packages and flake.lock #${LOCK_HASH}" >&2
