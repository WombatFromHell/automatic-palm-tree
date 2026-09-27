#!/usr/bin/env bash
# Updates metadata.json with the latest Brave release info.
# Dependencies: curl, jq, nix-prefetch-url, nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METADATA_JSON="$SCRIPT_DIR/metadata.json"
REPO="brave/brave-browser"
CHECK_ONLY=false

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

die() {
  echo "error: $*" >&2
  exit 1
}

# --- 1. Resolve Latest Release -----------------------------------------------

echo "==> Querying latest Brave release tag..." >&2

LATEST_TAG=$(
  curl -sfL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/${REPO}/releases/latest" |
    jq -r '.tag_name'
) || die "Failed to query GitHub API"

[[ "$LATEST_TAG" != "null" ]] || die "Could not resolve latest release tag"

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

declare -A ARCH_MAP=(
  ["x86_64-linux"]="amd64"
  ["aarch64-linux"]="arm64"
)

# Start with existing JSON structure, update version
TMP_META=$(mktemp)
jq --arg ver "$NEW_VERSION" '.version = $ver' "$METADATA_JSON" >"$TMP_META"

for system in "${!ARCH_MAP[@]}"; do
  suffix="${ARCH_MAP[$system]}"
  url="https://github.com/${REPO}/releases/download/${LATEST_TAG}/brave-browser_${NEW_VERSION}_${suffix}.deb"

  echo "==> Prefetching $system ($suffix)..." >&2

  hash_b32=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null) || die "Failed to prefetch $url"
  hash_sri=$(nix hash convert --hash-algo sha256 --to sri "$hash_b32")

  echo "    -> $hash_sri" >&2

  # Inject new hash into JSON using jq
  TMP_META_NEXT=$(mktemp)
  jq --arg sys "$system" --arg h "$hash_sri" '.hashes[$sys] = $h' "$TMP_META" >"$TMP_META_NEXT"
  mv "$TMP_META_NEXT" "$TMP_META"
done

mv "$TMP_META" "$METADATA_JSON"
echo "==> Updated $METADATA_JSON to version $NEW_VERSION" >&2

# --- 3. Sanity Build Check ---------------------------------------------------

if [[ "${SKIP_BUILD_CHECK:-0}" != "1" ]]; then
  echo "==> Verifying build..." >&2

  # Find flake root
  FLAKE_ROOT=""
  DIR="$SCRIPT_DIR"
  while [[ "$DIR" != "/" ]]; do
    if [[ -f "$DIR/flake.nix" ]]; then
      FLAKE_ROOT="$DIR"
      break
    fi
    DIR="$(dirname "$DIR")"
  done

  if [[ -z "$FLAKE_ROOT" ]]; then
    die "Could not find flake.nix upwards from $SCRIPT_DIR"
  fi

  # Attempt build via flake reference (assumes you have an output like .#hm-brave)
  # If not exposed, fallback to direct callPackage
  if ! nix build --no-link --impure --dry-run ".#hm-brave" 2>&1 | tail -n 20; then
    BUILD_EXPR="(import <nixpkgs> {}).callPackage '$SCRIPT_DIR/_package.nix' {}"
    if ! nix-build --no-out-link -E "$BUILD_EXPR" >/dev/null 2>&1; then
      die "Build verification failed after update."
    fi
  fi

  echo "==> Build OK" >&2
fi
