{
  self,
  lib,
  ...
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
    lib,
    config,
    options,
    ...
  }: {
    options = {
      overlays = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        internal = true;
        description = "Overlays to apply to pkgs when this feature is enabled.";
      };
      unstableOverlays = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        internal = true;
        description = "Overlays to apply to pkgsUnstable when this feature is enabled.";
      };

      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        internal = true;
        description = "Groups to add isAdmin-enabled users to when this feature is enabled.";
      };
      config.warnings =
        lib.optionals
        (config.extraGroups != [] && !(options ? users.users))
        ["Feature module declares extraGroups ${builtins.toJSON config.extraGroups} but 'users.users' is unavailable in standalone home-manager modules."];
    };
  };
in {
  inherit discoveredFeatures featureOptionsModule;
}
