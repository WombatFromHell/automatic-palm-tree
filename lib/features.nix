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
  # A feature dir may be a symlink (a checkout pointing at another tree); readDir
  # reports "symlink", so accepting only "directory" skipped it silently.
  featureDirs =
    lib.filterAttrs (_: t: t == "directory" || t == "symlink") (builtins.readDir featuresDir);

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
    (lib.filterAttrs (_: file: lib.elem (files."${file}.nix" or null) ["regular" "symlink"]) knownFiles))
  featureDirs;

  # ── feature path resolution (direct path interpolation, idiomatic) ──
  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));

  # One lookup for both consumers: an unknown feature names itself and the valid
  # set, so a host typo fails at the point it is written.
  lookupFeature = f:
    discoveredFeatures.${f} or (throw "Unknown feature '${f}'. Available: ${availableFeatures}");

  # Exactly one kernel-pinning feature per host. Both write `boot.kernelPackages` at
  # `mkDefault`, so a host listing two is an authoring error; the module system only
  # reports it as "defined multiple times" with two store paths and no host name, so it
  # is rejected here, at the point the feature list becomes module paths.
  # ponytail: reads the host's feature list only — a kernel module imported through a
  # host-local `nixosModules` file bypasses this. No host does that today
  # (hardware-configuration.nix sets kernelModules, never kernelPackages).
  kernelFeatures = ["nixos-cachyos" "nixos-kait2en"];

  # Resolves a host's feature list to file paths for one platform, reading the
  # single source of truth (discoveredFeatures) rather than re-walking features/.
  # A feature present without a module for this platform (hybrid) resolves to [].
  resolveFeaturePaths = featureList: platform: let
    kernels = lib.filter (f: lib.elem f kernelFeatures) featureList;
  in
    if lib.length kernels > 1
    then throw "Only one kernel feature per host, not ${lib.concatStringsSep ", " kernels}: both write boot.kernelPackages. Pick one in the host's features list."
    else
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
