#!/usr/bin/env bash
# hm-zed/update.sh
#
# Updates metadata.json with the latest Zed STABLE release info.
# Filters out preview/prerelease tags explicitly.
#
# Usage:
#   ./update.sh            # Update if newer version found
#   ./update.sh --check    # Exit 0 if up-to-date, 1 if update available (CI gating)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METADATA_JSON="$SCRIPT_DIR/metadata.json"
REPO="zed-industries/zed"
CHECK_ONLY=false

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

die() {
  echo "error: $*" >&2
  exit 1
}

# --- 1. Resolve Latest Stable Release ----------------------------------------

echo "==> Querying latest Zed stable release tag..." >&2

# Zed publishes many prereleases. We filter for:
# 1. Not a prerelease (.prerelease == false)
# 2. Tag matches vX.Y.Z strictly (no -pre, no -beta, etc.)
LATEST_TAG=$(
  curl -sfL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/${REPO}/releases?per_page=20" |
    jq -r '
      [.[] | select(.prerelease == false) | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))][0].tag_name
    '
) || die "Failed to query GitHub API"

[[ "$LATEST_TAG" != "null" ]] || die "Could not resolve latest stable release tag"

NEW_VERSION="${LATEST_TAG#v}"
CURRENT_VERSION=$(jq -r '.version' "$METADATA_JSON")

echo "==> Current: $CURRENT_VERSION | Latest: $NEW_VERSION" >&2

if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "==> Already up to date." >&2
  exit 0
fi

if $CHECK_ONLY; then
  echo "==> Update available: $CURRENT_VERSION -> $NEW_VERSION" >&2
  exit 1
fi

# --- 2. Prefetch Assets ------------------------------------------------------

# Map Nix systems to Zed asset suffixes
declare -A ARCH_MAP=(
  ["x86_64-linux"]="x86_64"
  # Uncomment when/if Zed starts publishing stable arm64 linux binaries
  # ["aarch64-linux"]="aarch64"
)

TMP_META=$(mktemp)
jq --arg ver "$NEW_VERSION" '.version = $ver' "$METADATA_JSON" >"$TMP_META"

for system in "${!ARCH_MAP[@]}"; do
  suffix="${ARCH_MAP[$system]}"
  url="https://github.com/${REPO}/releases/download/${LATEST_TAG}/zed-linux-${suffix}.tar.gz"

  echo "==> Prefetching $system ($suffix)..." >&2

  hash_b32=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null) || die "Failed to prefetch $url"
  hash_sri=$(nix hash convert --hash-algo sha256 --to sri "$hash_b32")

  echo "    -> $hash_sri" >&2

  TMP_META_NEXT=$(mktemp)
  jq --arg sys "$system" --arg h "$hash_sri" '.hashes[$sys] = $h' "$TMP_META" >"$TMP_META_NEXT"
  mv "$TMP_META_NEXT" "$TMP_META"
done

mv "$TMP_META" "$METADATA_JSON"
echo "==> Updated $METADATA_JSON to version $NEW_VERSION" >&2
