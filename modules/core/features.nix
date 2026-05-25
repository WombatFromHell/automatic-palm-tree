# modules/core/lib/features.nix
{
  lib,
  self,
}: let
  featuresDir = self + /modules/features;

  entries =
    if builtins.pathExists featuresDir
    then builtins.readDir featuresDir
    else {};

  featureDirs = lib.filterAttrs (_: t: t == "directory") entries;

  discoveredFeatures =
    lib.mapAttrs (
      featureName: _: let
        dirPath = featuresDir + "/${featureName}";
        files = builtins.readDir dirPath;
        nixFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) files;
      in
        lib.mapAttrs' (
          filename: _: let
            platform = lib.removeSuffix ".nix" filename;
          in
            lib.nameValuePair platform (dirPath + "/${filename}")
        )
        nixFiles
    )
    featureDirs;

  # Sorted for stable, readable error output
  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));
in {
  inherit discoveredFeatures;

  resolve = featureList: attrPath: let
    safeList =
      if featureList == null
      then []
      else featureList;
  in
    map (
      f:
      # Layer 1: is the feature name known at all?
        if !(discoveredFeatures ? ${f})
        then throw "Unknown feature '${f}'. Available features: ${availableFeatures}"
        # Layer 2: does this feature have a module for the requested platform?
        else if !(discoveredFeatures.${f} ? ${attrPath})
        then throw "Feature '${f}' has no '${attrPath}' module defined in modules/features/. Available platforms for this feature: ${lib.concatStringsSep ", " (lib.attrNames discoveredFeatures.${f})}"
        else discoveredFeatures.${f}.${attrPath}
    )
    safeList;
}
