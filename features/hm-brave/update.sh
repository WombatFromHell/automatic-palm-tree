#!/usr/bin/env bash
# Updates metadata.json with the latest Brave release info.
#
# Usage:
#   ./update.sh            # update to latest release (verify up-to-date state)
#   ./update.sh --check    # exit 0 if up to date, 1 if an update is available
#   ./update.sh <version>  # pin an explicit release version
#
# Dependencies: curl, jq, nix-prefetch-url, nix

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

REPO="brave/brave-browser"
HASH_KIND="sri"
SYSTEMS=(x86_64-linux aarch64-linux)

declare -A ARCH_MAP=(
  [x86_64-linux]=amd64
  [aarch64-linux]=arm64
)

asset_url() {
  echo "https://github.com/${REPO}/releases/download/v$2/brave-browser_${2}_${ARCH_MAP[$1]}.deb"
}

resolve_latest() {
  local tag
  tag=$(gh_api "/releases/latest" '.tag_name') || die "Failed to query GitHub API"
  [[ "$tag" != "null" ]] || die "Could not resolve latest release tag"
  printf '%s' "${tag#v}"
}

run_main "$@"
