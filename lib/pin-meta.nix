# Pin metadata contract — the one shape shared by metadata.json-backed derivations.
#
# Owns what lib/updater.sh writes and what features/*/_package.nix reads:
# version (tag/commit), url (template with {repo} {version} {arch}),
# arches (nix system -> release-arch token), hashes (nix system -> asset hash).
# lib/default.nix puts this attrset into both host package sets as the `pinMeta`
# member, so a derivation takes it like any other build dependency (`pinMeta.releaseAsset pin system`)
# and never re-implements the template or the lookup.
{lib, ...}: let
  inherit (lib) attrNames concatStringsSep filter hasAttr head last replaceStrings splitString;

  # ── boundary check: arches and hashes must describe the same systems ──
  # Runs on every resolution, so a malformed pin names the offending key here
  # instead of surfacing later as an unrelated nixpkgs platform error.
  pinnedSystems = pin: let
    arches = pin.arches or {};
    hashed = attrNames pin.hashes;
    declared = attrNames arches;
    unhashed = filter (s: !(hasAttr s pin.hashes)) declared;
    undeclared = filter (s: !(hasAttr s arches)) hashed;
  in
    if unhashed != []
    then throw "metadata for '${pin.repo}' declares '${concatStringsSep ", " unhashed}' in arches but no hash is pinned for it. Pinned systems: ${concatStringsSep ", " hashed}."
    else if arches != {} && undeclared != []
    then throw "metadata for '${pin.repo}' pins '${concatStringsSep ", " undeclared}' in hashes but arches declares only '${concatStringsSep ", " declared}'. Known systems: ${concatStringsSep ", " hashed}."
    else hashed;

  # asset hash pinned for one system
  assetHash = pin: system:
    pin.hashes.${system}
    or (throw "metadata for '${pin.repo}' pins no hash for system '${system}'. Pinned systems: ${concatStringsSep ", " (pinnedSystems pin)}.");

  # release asset for one system: fetchurl-ready {url, sha256}
  # ponytail: template expansion is duplicated in lib/updater.sh render_url; keep in sync,
  # upgrade path is a one-shot parity check over features/*/metadata.json
  releaseAsset = pin: system: let
    arch =
      pin.arches.${system}
      or (throw "metadata for '${pin.repo}' declares no arches entry for system '${system}'. Declared systems: ${concatStringsSep ", " (attrNames (pin.arches or {}))}.");
  in {
    url = replaceStrings ["{repo}" "{version}" "{arch}"] [pin.repo pin.version arch] pin.url;
    sha256 = assetHash pin system;
  };

  # GitHub source for one system: fetchFromGitHub-ready {owner, repo, rev, hash}
  gitSource = pin: system: let
    ownerRepo = splitString "/" pin.repo;
  in {
    owner = head ownerRepo;
    repo = last ownerRepo;
    rev = pin.version;
    hash = assetHash pin system;
  };
  pinContract = {
    inherit releaseAsset gitSource pinnedSystems;
  };
in
  pinContract
