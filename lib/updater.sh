#!/usr/bin/env bash
# lib/updater.sh — generic pin updater for metadata-backed derivations.
#
# Copy or symlink this file to features/<name>/update.sh. All feature-specific
# config lives in the feature's metadata.json, which the derivation
# (_package.nix) reads too:
#
#   repo      "owner/name" (used for GitHub API calls)
#   kind      "sri" (fetchurl release asset) | "nar" (fetchFromGitHub source)
#   strategy  "latest" | "semver" | "none"  (how to auto-discover a newer version)
#   url       asset/archive URL template with {repo}, {version}, {arch}
#   arches    optional: nix system -> {arch} token (for multi-arch assets)
#   version   pinned version/tag
#   hashes    nix system -> hash of the pinned asset
#
# CLI contract (identical for every feature):
#   ./update.sh            # update to latest; verify pin when strategy is "none"
#   ./update.sh --check    # exit 0 if up to date and pin valid;
#                          # exit 1 if an update is available or the pin moved
#   ./update.sh <ref>      # pin an explicit version/ref
#
# Dependencies: curl, jq, nix (nix-prefetch-url / nix store prefetch-file)

# Single-quoted jq filters below are intentional: the $vars are jq
# parameters bound via --arg, not shell variables.
# shellcheck disable=SC2016

set -euo pipefail

FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META="$FEATURE_DIR/metadata.json"

die() {
  echo "error: $*" >&2
  exit 1
}

j() { jq -r "$1" "$META"; }

REPO=$(j .repo)
KIND=$(j .kind)
STRATEGY=$(j .strategy)
URL=$(j .url)

meta_version() { j .version; }
meta_hash() { jq -r --arg s "$1" '.hashes[$s] // ""' "$META"; }
systems() { jq -r '.hashes | keys[]' "$META"; }
arch_of() { jq -r --arg s "$1" '.arches[$s] // ""' "$META"; }

# render_url <system> <version> -> expanded asset/archive URL
# ponytail: template expansion is duplicated in lib/pin-meta.nix releaseAsset; keep in sync,
# upgrade path is a one-shot parity check over features/*/metadata.json
render_url() {
  local u="$URL"
  u="${u//\{repo\}/$REPO}"
  u="${u//\{version\}/$2}"
  u="${u//\{arch\}/$(arch_of "$1")}"
  echo "$u"
}

# fetch_hash <url> -> hash in the format _package.nix expects
fetch_hash() {
  if [[ $KIND == nar ]]; then
    nix store prefetch-file --unpack --json "$1" | jq -r .hash
  else
    local b32
    b32=$(nix-prefetch-url --type sha256 "$1" 2>/dev/null) || return 1
    nix hash convert --hash-algo sha256 --to sri "$b32"
  fi
}

# Atomically rewrite metadata.json: meta_set <jq args...> <jq-filter>
meta_set() {
  local tmp
  tmp=$(mktemp)
  jq "$@" "$META" >"$tmp"
  mv "$tmp" "$META"
}

# exit 0 if the pinned assets still match metadata.json
verify_pin() {
  local ver sys cur actual
  ver=$(meta_version)
  for sys in $(systems); do
    cur=$(meta_hash "$sys")
    [[ -n $cur ]] || continue
    echo "==> Verifying $sys at $ver..." >&2
    actual=$(fetch_hash "$(render_url "$sys" "$ver")") || {
      echo "==> Failed to re-verify $sys at $ver." >&2
      return 1
    }
    if [[ $actual != "$cur" ]]; then
      echo "==> Pin moved for $sys at $ver: expected $cur but got $actual." >&2
      return 1
    fi
  done
  return 0
}

# echo the latest auto-discoverable version, or nothing if strategy is "none"
latest_version() {
  local endpoint filter tag
  case "$STRATEGY" in
  none)
    return 0
    ;;
  latest)
    endpoint="releases/latest"
    filter='.tag_name'
    ;;
  semver)
    endpoint="releases?per_page=20"
    filter='[.[] | select(.prerelease == false) | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))][0].tag_name'
    ;;
  *) die "unknown strategy '$STRATEGY' in $META" ;;
  esac
  tag=$(
    curl -sfL -H "Accept: application/vnd.github+json" \
      ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      "https://api.github.com/repos/${REPO}/${endpoint}" | jq -r "$filter"
  ) || die "Failed to query GitHub API"
  [[ $tag != "null" ]] || die "Could not resolve latest release for $REPO"
  printf '%s' "${tag#v}"
}

update_to() {
  local ver=$1 sys pinHash hashes='{}'
  for sys in $(systems); do
    echo "==> Prefetching $sys..." >&2
    pinHash=$(fetch_hash "$(render_url "$sys" "$ver")") || die "Failed to prefetch $sys at $ver"
    echo "    -> $pinHash" >&2
    hashes=$(jq -c --arg s "$sys" --arg v "$pinHash" '.[$s] = $v' <<<"$hashes")
  done
  meta_set --arg ver "$ver" --argjson hashes "$hashes" '.version = $ver | .hashes = $hashes'
  echo "==> Updated $META to version $ver" >&2
}

# CUR/LATEST are globals so both entry paths issue one upstream query.
update_available() {
  CUR=$(meta_version)
  LATEST=$(latest_version) || die "latest_version failed"
  [[ -n $LATEST && $LATEST != "$CUR" ]]
}

main() {
  local arg="${1:-}"
  if [[ $arg == "--check" ]]; then
    # Source-pinned (nar) features verify the pin; asset-pinned (sri)
    # features only compare versions (re-prefetching release assets is
    # expensive and only makes sense for small source archives).
    if [[ $KIND == nar ]]; then
      verify_pin || exit 1
    fi
    if update_available; then
      echo "==> Update available: $CUR -> $LATEST" >&2
      exit 1
    fi
    echo "==> Already up to date." >&2
    exit 0
  fi
  if [[ -n $arg ]]; then
    update_to "$arg"
    return 0
  fi
  if update_available; then
    echo "==> Updating $CUR -> $LATEST" >&2
    update_to "$LATEST"
  elif [[ $KIND == nar ]]; then
    verify_pin || exit 1
    echo "==> Pin $CUR is still valid." >&2
  else
    echo "==> Already up to date." >&2
  fi
}

main "$@"
