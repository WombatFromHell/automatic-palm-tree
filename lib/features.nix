{
  self,
  lib,
}: let
  featuresDir = self + /features;

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
        nixFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) files;
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

  featureOptionsModule = {
    options.overlays = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      internal = true;
      description = "Overlays to apply to pkgs when this feature is enabled.";
    };
    options.unstableOverlays = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      internal = true;
      description = "Overlays to apply to pkgsUnstable when this feature is enabled.";
    };
  };
in {
  inherit discoveredFeatures featureOptionsModule;
}
