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

  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));

  # Discover per-user home module paths for a given host.
  # Returns only existing files, so builders can safely pass all enabled usernames.
  resolveUserModules = hostsDir: hostname: usernames: let
    hostDir = hostsDir + "/${hostname}";
  in
    lib.filter builtins.pathExists (
      map (user: hostDir + "/home-${user}.nix") usernames
    );
in {
  inherit discoveredFeatures resolveUserModules;

  resolve = featureList: attrPath: host: let
    inherit (host) hostConfig;
    safeList =
      if featureList == null
      then []
      else featureList;

    # 1. Validate and get paths
    paths =
      map (
        f:
          if !(discoveredFeatures ? ${f})
          then throw "Unknown feature '${f}'. Available features: ${availableFeatures}"
          else if !(discoveredFeatures.${f} ? ${attrPath})
          then throw "Feature '${f}' has no '${attrPath}' module defined. Available: ${lib.concatStringsSep ", " (lib.attrNames discoveredFeatures.${f})}"
          else discoveredFeatures.${f}.${attrPath}
      )
      safeList;

    # 2. Evaluate in isolation JUST to extract the unfree lists
    extracted = lib.evalModules {
      modules =
        paths
        ++ [
          {
            options = {
              unfree = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                internal = true;
              };
            };
          }
          {_module.check = false;}
        ];
      # Provide dummy args so modules don't crash on destructuring,
      # but throw if they actually try to EVALUATE pkgs to build the list.
      specialArgs = {
        pkgs = throw "'unfree' lists must be static — they cannot reference pkgs.";
        pkgsUnstable = throw "'unfree' lists must be static — they cannot reference pkgsUnstable.";
        inherit lib hostConfig;
        config = {};
        options = {};
        inputs = {};
        self = {};
      };
    };
  in {
    # 3. Return the ORIGINAL paths. No wrapping needed!
    modules = paths;
    inherit (extracted.config) unfree;
  };
}
