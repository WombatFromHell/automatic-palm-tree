# Feature machinery — discovery and path resolution.
#
# The lowest layer of the loader: it only needs `lib` and `self` (to find
# features/). The config builders (lib/builders.nix) consume this. Feature *options* live in
# modules/feature-options.nix, beside every other module.
{
  lib,
  self,
  ...
}: let
  # ── feature discovery ──
  featuresDir = self + /features;
  featureDirs = lib.filterAttrs (_: t: t == "directory") (builtins.readDir featuresDir);

  # Feature file names: the module files are named after the platform, and
  # `_overlays.nix` is a module too — it contributes `nixpkgs.overlays`, so an
  # overlay can be gated on a feature option instead of frozen at build time.
  knownFiles = {
    nixos = "nixos";
    home = "home";
    overlays = "_overlays";
  };

  discoveredFeatures = lib.mapAttrs (featureName: _: let
    dirPath = featuresDir + "/${featureName}";
    files = builtins.readDir dirPath;
  in
    builtins.mapAttrs (name: file: dirPath + "/${file}.nix")
    (lib.filterAttrs (_: file: (files."${file}.nix" or null) == "regular") knownFiles))
  featureDirs;

  # ── feature path resolution (direct path interpolation, idiomatic) ──
  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));

  # One lookup for both consumers: an unknown feature names itself and the valid
  # set, so a host typo fails at the point it is written.
  lookupFeature = f:
    discoveredFeatures.${f} or (throw "Unknown feature '${f}'. Available: ${availableFeatures}");

  # Resolves a host's feature list to file paths for one platform, reading the
  # single source of truth (discoveredFeatures) rather than re-walking features/.
  # A feature present without a module for this platform (hybrid) resolves to [].
  resolveFeaturePaths = featureList: platform:
    lib.concatMap (
      f: let
        feature = lookupFeature f;
      in
        lib.optional (feature ? ${platform}) feature."${platform}"
    )
    featureList;
in {
  inherit discoveredFeatures resolveFeaturePaths;
}
