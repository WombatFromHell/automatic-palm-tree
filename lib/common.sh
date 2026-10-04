#!/usr/bin/env bash
# Shared pin-update framework for features/*/update.sh
#
# Each feature script defines the following, then calls `run_main "$@"`:
#   REPO           e.g. "tmux/tmux"
#   HASH_KIND      "sri" (fetchurl release asset) | "nar" (fetchFromGitHub source)
#   SYSTEMS        nix systems to pin, e.g. (x86_64-linux aarch64-linux)
#   asset_url <system> <version>   echo the asset/archive URL
#   resolve_latest               echo the latest auto-discoverable version
#                               (or nothing if the feature cannot auto-discover)
#
# CLI contract (identical for every feature):
#   ./update.sh            # update to latest; verify pin when not auto-discoverable
#   ./update.sh --check    # exit 0 if up to date and pin valid;
#                          # exit 1 if an update is available or the pin moved
#   ./update.sh <ref>      # pin an explicit version/ref

FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
METADATA_JSON="$FEATURE_DIR/metadata.json"

die() { echo "error: $*" >&2; exit 1; }

# GitHub API: gh_api <api-path> <jq-filter> (uses $REPO, honors GITHUB_TOKEN)
gh_api() {
  curl -sfL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/${REPO}$1" | jq -r "$2"
}

# SRI hash of a release asset (for fetchurl)
hash_sri() {
  local b32
  b32=$(nix-prefetch-url --type sha256 "$1" 2>/dev/null) || return 1
  nix hash convert --hash-algo sha256 --to sri "$b32"
}

# NAR hash of an unpacked archive (for fetchFromGitHub)
hash_nar() {
  nix store prefetch-file --unpack --json "$1" | jq -r .hash
}

# Atomically rewrite metadata.json: meta_update <jq args...> <jq-filter>
meta_update() {
  local tmp
  tmp=$(mktemp)
  jq "$@" "$METADATA_JSON" >"$tmp"
  mv "$tmp" "$METADATA_JSON"
}

meta_version() { jq -r .version "$METADATA_JSON"; }
meta_hash() { jq -r ".hashes[\"$1\"]" "$METADATA_JSON"; }

# Fetch the hash of the <version> asset for <system>
prefetch_system() {
  local url
  url=$(asset_url "$1" "$2")
  if [[ $HASH_KIND == nar ]]; then
    hash_nar "$url"
  else
    hash_sri "$url"
  fi
}

# exit 0 if the pinned assets still match metadata.json
verify_pin() {
  local ver sys cur actual
  ver=$(meta_version)
  for sys in "${SYSTEMS[@]}"; do
    cur=$(meta_hash "$sys")
    [[ -n "$cur" ]] || continue
    echo "==> Verifying $sys at $ver..." >&2
    actual=$(prefetch_system "$sys" "$ver") || {
      echo "==> Failed to re-verify $sys at $ver." >&2
      return 1
    }
    if [[ "$actual" != "$cur" ]]; then
      echo "==> Pin moved for $sys at $ver: expected $cur but got $actual." >&2
      return 1
    fi
  done
  return 0
}

# exit 0 if no newer version is available
check_updatable() {
  local latest cur
  cur=$(meta_version)
  latest=$(resolve_latest) || die "resolve_latest failed"
  if [[ -n "$latest" && "$latest" != "$cur" ]]; then
    echo "==> Update available: $cur -> $latest" >&2
    return 1
  fi
  return 0
}

update_to() {
  local ver=$1 sys h
  meta_update --arg ver "$ver" '.version = $ver'
  for sys in "${SYSTEMS[@]}"; do
    echo "==> Prefetching $sys..." >&2
    h=$(prefetch_system "$sys" "$ver") || die "Failed to prefetch $sys at $ver"
    echo "    -> $h" >&2
    meta_update --arg sys "$sys" --arg h "$h" '.hashes[$sys] = $h'
  done
  echo "==> Updated $METADATA_JSON to version $ver" >&2
}

run_main() {
  case "${1:-}" in
    --check)
      # Source-pinned (nar) features verify the pin; asset-pinned (sri)
      # features only compare versions (re-prefetching release assets is
      # expensive and only makes sense for small source archives).
      if [[ $HASH_KIND == nar ]]; then
        verify_pin || exit 1
      fi
      check_updatable || exit 1
      echo "==> Already up to date." >&2
      exit 0
      ;;
    "")
      local cur latest
      cur=$(meta_version)
      latest=$(resolve_latest) || die "resolve_latest failed"
      if [[ -n "$latest" && "$latest" != "$cur" ]]; then
        echo "==> Updating $cur -> $latest" >&2
        update_to "$latest"
      elif [[ $HASH_KIND == nar ]]; then
        verify_pin || exit 1
        echo "==> Pin $cur is still valid." >&2
      else
        echo "==> Already up to date." >&2
      fi
      ;;
    *)
      update_to "$1"
      ;;
  esac
}
