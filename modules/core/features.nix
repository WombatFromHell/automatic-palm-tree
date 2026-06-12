{
  self,
  lib,
  pkgsLib,
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

  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));
in {
  inherit discoveredFeatures;

  resolve = featureList: attrPath:
    assert builtins.elem attrPath ["nixos" "home"]; let
      paths =
        map (
          f:
            if !(discoveredFeatures ? ${f})
            then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
            else if !(discoveredFeatures.${f} ? ${attrPath})
            then throw "Feature '${f}' has no '${attrPath}' module. Available: ${lib.concatStringsSep ", " (lib.attrNames discoveredFeatures.${f})}"
            else discoveredFeatures.${f}.${attrPath}
        )
        featureList;

      extracted = pkgsLib.extractUnfree pkgsLib.mkUnfreeOptionsModule paths;
    in {
      modules = paths;
      inherit (extracted.config) unfree;
    };
}
