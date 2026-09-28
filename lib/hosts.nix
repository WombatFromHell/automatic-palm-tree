{
  lib,
  self,
  hostOptions,
  checkAdminWarning,
}: let
  # ── host discovery ──
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  hostEntries =
    lib.filterAttrs (
      n: t:
        (t == "regular" && lib.hasSuffix ".nix" n)
        || (t == "directory" && builtins.pathExists (hostsDir + "/${n}/default.nix"))
    )
    entries;

  parseHostEntry = filename: type: {
    isDir = type == "directory";
    name =
      if type == "directory"
      then filename
      else lib.removeSuffix ".nix" filename;
    path =
      if type == "directory"
      then hostsDir + "/${filename}/default.nix"
      else hostsDir + "/${filename}";
    hostDir =
      if type == "directory"
      then hostsDir + "/${filename}"
      else null;
  };

  validateHost = path:
    lib.evalModules {
      modules = [
        hostOptions
        (import path {inherit self lib;})
      ];
    };

  autoDiscoverModules = isDir: hostDir:
    if !isDir
    then {
      nixosModules = [];
      homeModules = {};
    }
    else {
      nixosModules =
        lib.optional (builtins.pathExists (hostDir + "/nixos.nix"))
        (hostDir + "/nixos.nix");
      homeModules = let
        dirEntries = builtins.readDir hostDir;
        homeFiles =
          lib.filterAttrs (
            n: t:
              t
              == "regular"
              && lib.hasPrefix "home-" n
              && lib.hasSuffix ".nix" n
          )
          dirEntries;
      in
        builtins.listToAttrs (
          map (
            filename: let
              user = lib.removeSuffix ".nix" (lib.removePrefix "home-" filename);
            in
              lib.nameValuePair user [(hostDir + "/${filename}")]
          ) (builtins.attrNames homeFiles)
        );
    };

  enrichHost = evaluatedConfig: autoModules: let
    allUsernames = lib.unique (
      (builtins.attrNames autoModules.homeModules)
      ++ (builtins.attrNames evaluatedConfig.homeModules)
    );
    impliedUsers = builtins.listToAttrs (
      map (user: {
        name = user;
        value = {enabled = true;};
      })
      allUsernames
    );
    mergedUsers = impliedUsers // evaluatedConfig.users;
    enabledUsers = lib.filterAttrs (_: u: u.enabled) mergedUsers;
    osUsernames = lib.attrNames enabledUsers;
    hasHomeModule = u: autoModules.homeModules ? ${u} || evaluatedConfig.homeModules ? ${u};
    hmEnabledFor = u: let uInfo = mergedUsers.${u}; in !(uInfo ? hmEnabled) || uInfo.hmEnabled;
    hmUsernames = builtins.filter (u: hasHomeModule u && hmEnabledFor u) osUsernames;
  in {
    nixosModules = autoModules.nixosModules ++ evaluatedConfig.nixosModules;
    homeModules = autoModules.homeModules // evaluatedConfig.homeModules;
    inherit osUsernames hmUsernames;
  };

  buildHost = filename: type: let
    entry = parseHostEntry filename type;
    inherit (entry) isDir name path hostDir;
    evaluatedHost = validateHost path;
    evaluatedConfig = evaluatedHost.config;
    autoModules = autoDiscoverModules isDir hostDir;
    enrichedHost = enrichHost evaluatedConfig autoModules;
    warnings = checkAdminWarning name evaluatedConfig;
  in
    evaluatedConfig
    // enrichedHost
    // {inherit name;}
    // lib.optionalAttrs (warnings != []) {inherit warnings;};

  discoveredHosts = lib.mapAttrs buildHost hostEntries;
in {
  inherit discoveredHosts;
}
