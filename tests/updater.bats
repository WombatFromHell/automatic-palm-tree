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
if [ "$1" = hash ]; then
  # --to base16 is how the updater reads back a hash metadata.json carries as an SRI.
  case "$*" in
    *--to\ base16*) printf '%s\n' "${PIN_HEX:-}" ;;
    *) printf '%s\n' "${PIN_SRI:-sha256-STUBASSET}" ;;
  esac
  exit "${HASH_EXIT:-0}"
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
# Honour -o: the signature path writes the fetched files to disk, and a stub that only printed
# would leave the updater verifying a missing file.
out=/dev/stdout
args=("$@")
for i in "${!args[@]}"; do
  if [ "${args[i]}" = -o ]; then out="${args[i + 1]}"; fi
done
url="${args[-1]}" # the URL is the last argument at every call site, with or without -o
body='' rc=0
case "$url" in
  *api.github.com*)
    if [ -n "${RELEASES_JSON:-}" ]; then body="$RELEASES_JSON"
    else body=$(printf '[{"tag_name":"%s","name":"Release %s","prerelease":false,"draft":false,"published_at":"2026-01-01T00:00:00Z"}]' "${LATEST_TAG:-0.0}" "${LATEST_TAG:-0.0}")
    fi
    rc="${API_EXIT:-0}"
    ;;
  *.sha256.asc)
    body="${SIG_ASC:-}"
    rc="${SIG_EXIT:-0}"
    ;;
  *.sha256)
    body=$(printf '%s  asset' "${PUBLISHED_SHA:-}")
    rc="${PUBLISHED_EXIT:-0}"
    ;;
esac
printf '%s\n' "$body" >"$out"
exit "$rc"
EOF

  feature="$stubs/features/hm-test"
  mkdir -p "$feature"
  ln -s "$repo/lib/updater.sh" "$feature/update.sh"
}

# Two throwaway keys per signed test: Brave signs stable and pre-release checksums with different
# keys, so the suite needs both to prove a pre-release signature is refused. gen_key makes its own
# homedir, so no host keyring is touched.
fixture_keys() {
  keys="$stubs/keys"
  mkdir -p "$keys"
  gen_key "$keys/release" "Fixture Checksums Release" >"$keys/release.fp"
  gen_key "$keys/pre" "Fixture Checksums Pre Release" >"$keys/pre.fp"
  GNUPGHOME="$keys/release" gpg --quiet --export --armor >"$keys/release.asc" 2>/dev/null
  GNUPGHOME="$keys/pre" gpg --quiet --export --armor >"$keys/pre.asc" 2>/dev/null
}

# gen_key <home> <uid> -> the primary fingerprint, in a throwaway homedir so no host keyring is
# touched. pub: and sub: precede their fpr: lines, so only the primary one is reported.
gen_key() {
  mkdir -p "$1"
  chmod 700 "$1"
  # loopback + empty passphrase: --batch keygen otherwise asks for a pinentry that does not exist.
  GNUPGHOME="$1" gpg --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' --gen-key <<EOF 2>/dev/null
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Name-Real: $2
Name-Email: checksums-release@brave.test
EOF
  GNUPGHOME="$1" gpg --list-keys --with-colons |
    awk -F: '/^pub:/ {p = 1; next} /^sub:/ {p = 0; next} /^fpr:/ && p {print $10}' | head -n1
}

# A detached signature over exactly the bytes the curl stub serves for `<asset>.sha256`, printed on
# stdout so the caller can export it on the `run` line — a plain assignment would not reach the
# stubbed curl.
sign_published() { # <home> <checksum-line>
  printf '%s  asset\n' "$2" >"$stubs/checksum"
  GNUPGHOME="$1" gpg --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' \
    --armor --detach-sign --output "$stubs/checksum.asc" "$stubs/checksum" 2>/dev/null
  printf '%s' "$(cat "$stubs/checksum.asc")"
}

# An sri pin that carries a vendored signing key: the shape the signature rules bind on.
write_signed_meta() {
  fixture_keys
  jq -n --arg fp "$(cat "$keys/release.fp")" '{repo: "brave/brave-browser", kind: "sri",
          strategy: "latest", channel: ".name | startswith(\"Release \")",
          url: "https://github.com/{repo}/releases/download/v{version}/brave-browser_{version}_amd64.deb",
          version: "1.98.63", hashes: {"x86_64-linux": "sha256-OLD"},
          sigKey: {source: "https://brave-browser-downloads.s3.brave.com/keys/github-checksums-release.asc",
                   file: "checksums-key.asc", fingerprints: [$fp]}}' >"$feature/metadata.json"
  cp "$keys/release.asc" "$feature/checksums-key.asc"
}

# A nar pin on a fixed commit: `version` is the revision itself, so nothing is auto-discoverable.
write_meta() {
  jq -n '{repo: "rylos/yazi", kind: "nar", strategy: "none",
          url: "https://github.com/{repo}/archive/{version}.tar.gz",
          version: "7c7e147af5e628c45997aea1465d656b6a5b8bce",
          hashes: {"x86_64-linux": "sha256-STUBSOURCE"}}' >"$feature/metadata.json"
}

# An asset pin on Brave's deb: the shape the published-checksum and downgrade rules bind on.
write_sri_meta() {
  jq -n '{repo: "brave/brave-browser", kind: "sri", strategy: "latest",
          url: "https://github.com/{repo}/releases/download/v{version}/brave-browser_{version}_amd64.deb",
          version: "1.98.63", hashes: {"x86_64-linux": "sha256-OLD"}}' >"$feature/metadata.json"
}

meta() { jq -r "$1" "$feature/metadata.json"; }
update() { PATH="$stubs:$PATH" bash "$feature/update.sh" "$@"; }

# Two distinct 64-hex digests, so the checksum comparisons compare something real.
hex_one() { printf '%064x' 1; }
hex_two() { printf '%064x' 2; }

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

# Trust is established at pin time, not at eval: Nix only verifies the hash it is handed.
@test "pinning an asset whose published checksum disagrees with what we fetched refuses it" {
  write_sri_meta
  PIN_HEX=$(hex_one) PUBLISHED_SHA=$(hex_two) run update 1.98.64
  [ "$status" -eq 1 ]
  assert_out "checksum mismatch"
  [ "$(meta .version)" = "1.98.63" ]
  [ "$(meta '.hashes["x86_64-linux"]')" = "sha256-OLD" ]
}

@test "pinning an asset whose release publishes no checksum keeps the fetched hash" {
  write_sri_meta
  PIN_HEX=$(hex_one) PUBLISHED_EXIT=22 run update 1.98.64
  [ "$status" -eq 0 ]
  [ "$(meta .version)" = "1.98.64" ]
  assert_call "curl -fsSL --.*1.98.64_amd64.deb.sha256"
}

@test "pinning an asset whose published checksum matches writes the new pin" {
  write_sri_meta
  PIN_HEX=$(hex_one) PUBLISHED_SHA=$(hex_one) run update 1.98.64
  [ "$status" -eq 0 ]
  [ "$(meta .version)" = "1.98.64" ]
  # A pin with no sigKey fetches no signature at all: ghostty, zed, tmux and yazi stay as they were.
  assert_no_call "sha256.asc"
}

# Nix only verifies the hash it is handed, so the published checksum has to be trusted before the
# pin is written. The key is vendored beside metadata.json, not fetched: fetching it would trust
# the same channel the checksum came from.
@test "a published checksum signed by the vendored key writes the new pin" {
  write_signed_meta
  local sig
  sig=$(sign_published "$keys/release" "$(hex_one)")
  PIN_HEX=$(hex_one) SIG_ASC="$sig" PUBLISHED_SHA=$(hex_one) run update 1.98.64
  [ "$status" -eq 0 ]
  [ "$(meta .version)" = "1.98.64" ]
  [ "$(meta '.hashes["x86_64-linux"]')" = "sha256-STUBASSET" ] # the fetched hash stays pinned; the signature gates the write
  assert_call "deb.sha256.asc"                                 # the signature was fetched alongside the checksum
}

@test "a published checksum whose signature does not match the checksum is refused" {
  write_signed_meta
  local sig
  sig=$(sign_published "$keys/release" "$(hex_two)") # signed a different digest
  PIN_HEX=$(hex_one) SIG_ASC="$sig" PUBLISHED_SHA=$(hex_one) run update 1.98.64
  [ "$status" -eq 1 ]
  assert_out "not signed by"
  [ "$(meta .version)" = "1.98.63" ]
  [ "$(meta '.hashes["x86_64-linux"]')" = "sha256-OLD" ]
}

# Brave signs beta and nightly checksums with a separate key, so an asset signed by a key we do
# not vendor is a pre-release asset, not a stable one.
@test "a checksum signed by a key we do not vend is refused" {
  write_signed_meta
  local sig
  sig=$(sign_published "$keys/pre" "$(hex_one)")
  PIN_HEX=$(hex_one) SIG_ASC="$sig" PUBLISHED_SHA=$(hex_one) run update 1.98.64
  [ "$status" -eq 1 ]
  assert_out "not signed by"
  [ "$(meta .version)" = "1.98.63" ]
}

@test "an unsigned asset is refused when the pin declares a signing key" {
  write_signed_meta
  PIN_HEX=$(hex_one) PUBLISHED_SHA=$(hex_one) SIG_EXIT=22 run update 1.98.64
  [ "$status" -eq 1 ]
  assert_out "no signature"
  [ "$(meta .version)" = "1.98.63" ]
}

@test "release discovery skips prereleases, beta and nightly" {
  write_signed_meta
  RELEASES_JSON='[
    {"tag_name":"v1.101.32","name":"Nightly v1.101.32","prerelease":false,"draft":false,"published_at":"2026-11-06T13:24:58Z"},
    {"tag_name":"v1.100.50","name":"Beta v1.100.50","prerelease":false,"draft":false,"published_at":"2026-11-06T05:16:54Z"},
    {"tag_name":"v1.99.54","name":"Release v1.99.54","prerelease":true,"draft":false,"published_at":"2026-11-03T22:13:59Z"},
    {"tag_name":"v1.98.63","name":"Release v1.98.63","prerelease":false,"draft":true,"published_at":"2026-10-30T05:50:37Z"},
    {"tag_name":"v1.99.55","name":"Release v1.99.55","prerelease":false,"draft":false,"published_at":"2026-11-04T18:56:17Z"}]' run update --check
  [ "$status" -eq 1 ]
  assert_out "Update available: 1.98.63 -> 1.99.55"
}

# The real vendored keyring, real gpg, no stubs: a silent Brave key rotation has to fail here
# rather than silently verify against a key nobody reviewed.
@test "the vendored Brave keyring matches the fingerprints metadata.json pins" {
  local home got want
  home=$(mktemp -d)
  chmod 700 "$home"
  gpg --quiet --dearmor <"$repo/features/hm-brave/checksums-key.asc" >"$home/kr.gpg"
  got=$(GNUPGHOME="$home" gpg --no-default-keyring --keyring "$home/kr.gpg" --list-keys --with-colons |
    awk -F: '/^pub:/ {p = 1; next} /^sub:/ {p = 0; next} /^fpr:/ && p {print $10}' | sort)
  want=$(jq -r '.sigKey.fingerprints[]' "$repo/features/hm-brave/metadata.json" | sort)
  [ "$got" = "$want" ]
  [ "$(jq -r '.sigKey.file' "$repo/features/hm-brave/metadata.json")" = "checksums-key.asc" ]
}

@test "pinning an older version is refused before anything is fetched" {
  write_sri_meta
  run update 1.97.10
  [ "$status" -eq 1 ]
  assert_out "refusing downgrade 1.98.63 -> 1.97.10"
  assert_no_call "prefetch"
  [ "$(meta .version)" = "1.98.63" ]
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
