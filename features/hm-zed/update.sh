#!/usr/bin/env bash
# hm-zed/update.sh
#
# Updates metadata.json with the latest Zed STABLE release info.
# Filters out preview/prerelease tags explicitly.
#
# Usage:
#   ./update.sh            # update to latest stable release (verify up-to-date state)
#   ./update.sh --check    # exit 0 if up to date, 1 if an update is available
#   ./update.sh <version>  # pin an explicit stable version

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

REPO="zed-industries/zed"
HASH_KIND="sri"
SYSTEMS=(x86_64-linux)
# Uncomment when/if Zed starts publishing stable arm64 linux binaries
# SYSTEMS+=(aarch64-linux)

asset_url() {
  echo "https://github.com/${REPO}/releases/download/v$2/zed-linux-${1%-linux}.tar.gz"
}

resolve_latest() {
  local tag
  # Zed publishes many prereleases. We filter for:
  # 1. Not a prerelease (.prerelease == false)
  # 2. Tag matches vX.Y.Z strictly (no -pre, no -beta, etc.)
  tag=$(gh_api "/releases?per_page=20" '
    [.[] | select(.prerelease == false) | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))][0].tag_name
  ') || die "Failed to query GitHub API"
  [[ "$tag" != "null" ]] || die "Could not resolve latest stable release tag"
  printf '%s' "${tag#v}"
}

run_main "$@"
