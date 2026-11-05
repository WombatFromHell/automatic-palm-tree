#!/usr/bin/env bash
# apps.cache-check: an eval-only pre-flight that says which caches an enabled feature needs
# and this host does not substitute from. The app reads the flake it is run from, so the fixture
# is a copy of the repo with one host's flakeCache.enable narrowed - no fake host, no build.
load helpers

repo_copy() {
  fixture="$stubs/repo"
  mkdir -p "$fixture"
  tar -C "$repo" --exclude=.git --exclude=.ank --exclude=tests -cf - . | tar -C "$fixture" -xf -
}

# methyl enables nixos-cachyos, so it asks for the nix-community cache (modules/features/nixos-cachyos/nixos.nix).
run_app() {
  cd "$fixture"
  run nix run .#apps.x86_64-linux.cache-check -- "$1"
}

@test "cache-check exits 0 when the host enables every cache its features require" {
  repo_copy
  run_app methyl
  [ "$status" -eq 0 ]
  assert_no_out "flakeCache:"
}

@test "cache-check exits 1 naming a cache the host forgot to enable" {
  repo_copy
  printf '{hostLib, ...}:\nhostLib.mergeModules (\n  hostLib.profiles ../methyl-base/profiles ["methyl-kde"]\n  ++ [{features = ["nixos-cachyos"]; nixosModules = [{flakeCache.enable = [];}];}]\n)\n' >"$fixture/hosts/methyl/default.nix"
  run_app methyl
  [ "$status" -eq 1 ]
  assert_out "flakeCache:"
  assert_out "https://nix-community.cachix.org"
  # The warning wraps, so the cache name and the fix are on different lines (modules/caches.nix).
  assert_out 'Add "nix-community" to'
  assert_out '`flakeCache.enable` to pull it from the cache'
}

@test "cache-check refuses a host that is not in the flake" {
  repo_copy
  run_app nosuchhost
  [ "$status" -eq 2 ]
  assert_out "unknown host 'nosuchhost'"
}
