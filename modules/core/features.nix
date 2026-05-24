# modules/core/lib/features.nix
{
  lib,
  self,
}: let
  featuresDir = self + /modules/features;

  # 1. Auto-discover features from the filesystem
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
in {
  # 2. Expose the discovered tree so the core loader can assign it to `flake.features`
  inherit discoveredFeatures;

  # 3. The resolver function used by the builders
  resolve = featureList: attrPath: let
    safeList =
      if featureList == null
      then []
      else featureList;
  in
    map (
      f:
        if discoveredFeatures ? ${f} && discoveredFeatures.${f} ? ${attrPath}
        then discoveredFeatures.${f}.${attrPath}
        else throw "Feature '${f}' has no '${attrPath}' module defined in modules/features/"
    )
    safeList;
}
