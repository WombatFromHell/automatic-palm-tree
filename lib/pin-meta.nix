# Pin metadata contract — the one shape shared by metadata.json-backed derivations.
#
# Owns what lib/updater.sh writes and what features/*/_package.nix reads:
# version (tag/commit), url (template with {repo} {version} {arch}),
# arches (nix system -> release-arch token), hashes (nix system -> asset hash),
# and optional depsHashes (nix system -> lockfile-closure hash for fetchPnpmDeps).
# lib/default.nix puts this attrset into both host package sets as the `pinMeta`
# member, so a derivation takes it like any other build dependency (`pinMeta.releaseAsset pin system`)
# and never re-implements the template or the lookup.
{lib, ...}: let
  inherit (lib) attrNames concatStringsSep filter hasAttr head last replaceStrings splitString;

  # ── boundary check: arches, hashes, and depsHashes must describe the same systems ──
  # Runs on every resolution, so a malformed pin names the offending key here
  # instead of surfacing later as an unrelated nixpkgs platform error.
  pinnedSystems = pin: let
    arches = pin.arches or {};
    deps = pin.depsHashes or {};
    hashed = attrNames pin.hashes;
    declared = attrNames arches;
    unhashed = filter (s: !(hasAttr s pin.hashes)) declared;
    undeclared = filter (s: !(hasAttr s arches)) hashed;
    unhashedDeps = filter (s: !(hasAttr s deps)) hashed;
    undeclaredDeps = filter (s: !(hasAttr s pin.hashes)) (attrNames deps);
  in
    if unhashed != []
    then throw "metadata for '${pin.repo}' declares '${concatStringsSep ", " unhashed}' in arches but no hash is pinned for it. Pinned systems: ${concatStringsSep ", " hashed}."
    else if arches != {} && undeclared != []
    then throw "metadata for '${pin.repo}' pins '${concatStringsSep ", " undeclared}' in hashes but arches declares only '${concatStringsSep ", " declared}'. Known systems: ${concatStringsSep ", " hashed}."
    else if undeclaredDeps != []
    then throw "metadata for '${pin.repo}' pins '${concatStringsSep ", " undeclaredDeps}' in depsHashes but hashes pins only '${concatStringsSep ", " hashed}'."
    else if deps != {} && unhashedDeps != []
    then throw "metadata for '${pin.repo}' pins '${concatStringsSep ", " hashed}' in hashes but depsHashes declares only '${concatStringsSep ", " (attrNames deps)}'."
    else hashed;

  # asset hash pinned for one system
  assetHash = pin: system:
    pin.hashes.${system}
    or (throw "metadata for '${pin.repo}' pins no hash for system '${system}'. Pinned systems: ${concatStringsSep ", " (pinnedSystems pin)}.");

  # Dependency-closure hash pinned for one system: the sha256 of the lockfile closure
  # built from the pinned source, for a derivation's `fetchPnpmDeps`.
  # Optional; lib/updater.sh clears depsHashes when the pin moves.
  depsHash = pin: system:
    pin.depsHashes.${system}
    or (throw "metadata for '${pin.repo}' pins no dependency-closure hash for system '${system}'. Recompute it with fetchPnpmDeps hash=\"\" and record it in depsHashes. Pinned systems: ${concatStringsSep ", " (pinnedSystems pin)}.");

  # release asset for one system: fetchurl-ready {url, sha256}
  # lib/updater.sh render_url expands the same template in bash; the two runtimes
  # cannot share code, so tests/run.sh diffs them byte-for-byte over every pin x system.
  # `arch` is lazy on purpose: the throw below fires only when {arch} is in the template,
  # which is what lets a single-arch pin with no `arches` key (hm-tmux) still resolve.
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
    inherit depsHash releaseAsset gitSource pinnedSystems;
  };
in
  pinContract
