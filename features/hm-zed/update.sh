#!/usr/bin/env bash
# 
# Fetches the latest Zed stable release tag from GitHub, prefetches the
# per-arch tar.gz hashes, and rewrites version/sha256 in _package.nix in
# place. Relies on `url` already being templated with ${version} — only
# `version` and each system's `sha256` are ever touched.
#
# Usage:
#   ./update.sh            # update if newer version found
#   ./update.sh --check    # exit 0/1 without writing, for CI gating

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NIX="$SCRIPT_DIR/_package.nix"
REPO="zed-industries/zed"
CHECK_ONLY=false

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

# --- 1. Resolve the latest stable release tag -------------------------------
# Zed tags stable releases as vX.Y.Z but also publishes preview releases
# (vX.Y.Z-pre) which we want to skip — filter to plain vX.Y.Z tags only.

echo "==> Querying latest Zed release tag..." >&2

latest_tag="$(
  curl -sfL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/${REPO}/releases?per_page=20" |
    jq -r '[.[] | select(.prerelease == false) | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))][0].tag_name'
)"

if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
  echo "error: could not resolve latest stable release tag from GitHub API" >&2
  exit 1
fi

new_version="${latest_tag#v}"

current_version="$(
  sed -nE 's/^\s*version = "(.*)";/\1/p' "$PACKAGE_NIX" | head -n1
)"

echo "==> current: $current_version  latest: $new_version" >&2

if [[ "$new_version" == "$current_version" ]]; then
  echo "==> already up to date" >&2
  exit 0
fi

if $CHECK_ONLY; then
  echo "==> update available: $current_version -> $new_version" >&2
  exit 1
fi

# --- 2. Bump top-level version = "...";  --------------------------------
# This alone updates every `url` field, since they interpolate ${version}.

sed -i -E "s/^(\s*version = \")[^\"]*(\";)/\1${new_version}\2/" "$PACKAGE_NIX"

# --- 3. Prefetch each per-arch asset and patch its sha256 in place ---------

declare -A ASSET_SUFFIX=(
  ["x86_64-linux"]="x86_64"
  # zed-linux-aarch64.tar.gz also exists upstream — uncomment to track it
  # once/if added to `assets` in _package.nix:
  # ["aarch64-linux"]="aarch64"
)

for system in "${!ASSET_SUFFIX[@]}"; do
  suffix="${ASSET_SUFFIX[$system]}"
  url="https://github.com/${REPO}/releases/download/${latest_tag}/zed-linux-${suffix}.tar.gz"

  echo "==> prefetching $system : $url" >&2

  hash_b32="$(nix-prefetch-url --type sha256 "$url" 2>/dev/null | tail -n1)"
  if [[ -z "$hash_b32" ]]; then
    echo "error: failed to prefetch $url (has the asset naming changed upstream?)" >&2
    exit 1
  fi

  hash_sri="$(nix hash convert --hash-algo sha256 --to sri "$hash_b32")"
  echo "    -> $hash_sri" >&2

  # Only replace the sha256 line inside this system's block, identified by
  # the preceding `"<system>" = {` line — never touches `url`.
  awk -v sys="\"${system}\" = {" -v hash="$hash_sri" '
    BEGIN { in_block = 0 }
    {
      if ($0 ~ sys) { in_block = 1 }
      if (in_block && $0 ~ /sha256 = "/) {
        sub(/sha256 = "[^"]*"/, "sha256 = \"" hash "\"")
        in_block = 0
      }
      print
    }
  ' "$PACKAGE_NIX" >"${PACKAGE_NIX}.tmp" && mv "${PACKAGE_NIX}.tmp" "$PACKAGE_NIX"
done

echo "==> updated $PACKAGE_NIX: $current_version -> $new_version" >&2

# --- 4. Optional: sanity build check ----------------------------------------

if [[ "${SKIP_BUILD_CHECK:-0}" != "1" ]]; then
  echo "==> building to verify hashes..." >&2

  find_flake_root() {
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
      if [[ -f "$dir/flake.nix" ]]; then
        echo "$dir"
        return 0
      fi
      dir="$(dirname "$dir")"
    done
    return 1
  }

  FLAKE_ROOT="$(find_flake_root "$SCRIPT_DIR")" || {
    echo "error: could not locate flake.nix by walking up from $SCRIPT_DIR" >&2
    exit 1
  }

  build_expr='
    let
      flake = builtins.getFlake (toString '"$FLAKE_ROOT"');
      pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
    in
      pkgs.callPackage '"$PACKAGE_NIX"' {}
  '

  if ! nix build --no-link --impure --expr "$build_expr" 2>&1 | tail -n 40; then
    echo "error: build failed after update — leaving file changed for inspection" >&2
    exit 1
  fi
  echo "==> build OK" >&2
fi
