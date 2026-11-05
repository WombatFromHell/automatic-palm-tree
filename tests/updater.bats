#!/usr/bin/env bats
# lib/updater.sh against a PATH stub: what a fixed revision pin does, what it rewrites, and what it
# refuses. No real eval, no real fetch — `nix store prefetch-file`, `nix-prefetch-url` and `curl`
# are stubbed, so the assertions are the metadata contract, not the network.

load helpers

setup() {
  harness_stub_dir
  export CALLS="$calls"

  # Quoted heredoc so the stub bodies survive unevaluated.
  stub nix <<'EOF'
#!/usr/bin/env bash
echo "nix $*|pwd=$(pwd)" >> "$CALLS"
if [ "$1" = store ]; then
  printf '{"hash":"%s","path":"/nix/store/fake"}\n' "${PREFETCH_HASH:-sha256-STUBSOURCE}"
  exit "${PREFETCH_EXIT:-0}"
fi
exit 0
EOF
  stub nix-prefetch-url <<'EOF'
#!/usr/bin/env bash
echo "nix-prefetch-url $*" >> "$CALLS"
printf 'sha256-STUBASSET\n'
EOF
  stub curl <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
printf '{"tag_name":"%s"}\n' "${LATEST_TAG:-0.0}"
EOF

  feature="$stubs/features/hm-test"
  mkdir -p "$feature"
  ln -s "$repo/lib/updater.sh" "$feature/update.sh"
}

# A nar pin on a fixed commit: `version` is the revision itself, so nothing is auto-discoverable.
write_meta() {
  jq -n '{repo: "rylos/yazi", kind: "nar", strategy: "none",
          url: "https://github.com/{repo}/archive/{version}.tar.gz",
          version: "7c7e147af5e628c45997aea1465d656b6a5b8bce",
          hashes: {"x86_64-linux": "sha256-STUBSOURCE"}}' >"$feature/metadata.json"
}

meta() { jq -r "$1" "$feature/metadata.json"; }
update() { PATH="$stubs:$PATH" bash "$feature/update.sh" "$@"; }

@test "a fixed revision pin is verified, never auto-discovered" {
  write_meta
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"is still valid"* ]]
  [ "$(grep -c '^curl' "$calls")" = "0" ]
  [ "$(meta .version)" = "7c7e147af5e628c45997aea1465d656b6a5b8bce" ]
}

@test "--check fails when the archive behind the pinned revision has moved" {
  write_meta
  PREFETCH_HASH=sha256-DIFFERENT run update --check
  [ "$status" -eq 1 ]
  [[ $output == *"Pin moved"* ]]
  [[ $output == *"sha256-DIFFERENT"* ]]
}

@test "pinning a revision rewrites version and hashes" {
  jq -n '{repo: "tmux/tmux", kind: "nar", strategy: "none",
          url: "https://github.com/{repo}/archive/{version}.tar.gz",
          version: "3.8", hashes: {"x86_64-linux": "sha256-OLD"}}' >"$feature/metadata.json"
  PREFETCH_HASH=sha256-NEWSOURCE run update abc1234
  [ "$status" -eq 0 ]
  [ "$(meta .version)" = "abc1234" ]
  [ "$(meta '.hashes["x86_64-linux"]')" = "sha256-NEWSOURCE" ]
}

@test "a failed prefetch leaves metadata.json untouched" {
  jq -n '{repo: "tmux/tmux", kind: "nar", strategy: "none",
          url: "https://github.com/{repo}/archive/{version}.tar.gz",
          version: "3.8", hashes: {"x86_64-linux": "sha256-OLD"}}' >"$feature/metadata.json"
  PREFETCH_EXIT=1 run update abc1234
  [ "$status" -ne 0 ]
  [ "$(meta .version)" = "3.8" ]
  [ "$(meta '.hashes["x86_64-linux"]')" = "sha256-OLD" ]
}

@test "an asset pin compares versions and never re-fetches the asset" {
  jq -n '{repo: "zed-industries/zed", kind: "sri", strategy: "latest",
          url: "https://github.com/{repo}/releases/download/v{version}/zed-linux-x86_64.tar.gz",
          version: "0.22.0", hashes: {"x86_64-linux": "sha256-STUBASSET"}}' >"$feature/metadata.json"
  LATEST_TAG=0.22.0 run update --check
  [ "$status" -eq 0 ]
  [[ $output == *"Already up to date"* ]]
  [ "$(grep -c 'nix-prefetch-url' "$calls")" = "0" ]
}

@test "an asset pin reports a newer release as an update" {
  jq -n '{repo: "zed-industries/zed", kind: "sri", strategy: "latest",
          url: "https://github.com/{repo}/releases/download/v{version}/zed-linux-x86_64.tar.gz",
          version: "0.22.0", hashes: {"x86_64-linux": "sha256-STUBASSET"}}' >"$feature/metadata.json"
  LATEST_TAG=0.23.1 run update --check
  [ "$status" -eq 1 ]
  [[ $output == *"Update available: 0.22.0 -> 0.23.1"* ]]
}

# update-all.sh runs the whole pin sweep from its own directory, so the fixture repo is the
# scratch dir itself: its features/hm-test entry is the symlink setup() made.
all() { PATH="$stubs:$PATH" run bash "$stubs/update-all.sh" "$@"; }

all_repo() {
  cp "$repo/update-all.sh" "$stubs/update-all.sh"
  write_meta
}

@test "update-all.sh --check passes a repo whose pins hold" {
  all_repo
  all --check
  [ "$status" -eq 0 ]
  assert_out "Already up to date"
}

@test "update-all.sh --check aborts on a pin that moved" {
  all_repo
  PREFETCH_HASH=sha256-DIFFERENT all --check
  [ "$status" -eq 1 ]
  assert_out "Pin moved"
}

@test "update-all.sh refuses an update.sh that is a copy of lib/updater.sh" {
  all_repo
  rm "$stubs/features/hm-test/update.sh"
  cp "$repo/lib/updater.sh" "$stubs/features/hm-test/update.sh"
  all --check
  [ "$status" -eq 1 ]
  assert_out "copies, not symlinks"
}
