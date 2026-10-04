#!/usr/bin/env bash
# hm-tmux/update.sh
#
# Updates metadata.json with the NAR hash of the unpacked source archive
# for the given tmux ref (release tag or full commit hash). This is what
# fetchFromGitHub's `hash` attribute expects (NAR of the unpacked tree).
#
# tmux publishes irregular release tags (e.g. 3.8-rc3, 3.7c), so the ref
# is explicit rather than auto-discovered.
#
# Usage:
#   ./update.sh            # verify the pinned ref still matches metadata.json
#   ./update.sh <ref>      # e.g. ./update.sh 3.9  or ./update.sh 331611b...
#   ./update.sh --check    # same as no args: exit 0 if the pin still matches

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

REPO="tmux/tmux"
HASH_KIND="nar"
SYSTEMS=(x86_64-linux)

asset_url() {
  echo "https://github.com/${REPO}/archive/$2.tar.gz"
}

# No auto-discovery: tmux tags are irregular (3.8-rc3, 3.7c, ...)
resolve_latest() { :; }

run_main "$@"
