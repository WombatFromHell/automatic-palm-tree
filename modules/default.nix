{
  self,
  lib,
  inputs,
  ...
}: let
  flakeLib = import ../lib.nix {inherit lib self inputs;};

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
        flakeLib.hostOptions
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
    hmUsernames =
      builtins.filter (
        u:
          (autoModules.homeModules ? ${u} || evaluatedConfig.homeModules ? ${u})
          && (mergedUsers.${u}.hmEnabled or true)
      )
      osUsernames;
  in {
    nixosModules = autoModules.nixosModules ++ evaluatedConfig.nixosModules;
    homeModules = autoModules.homeModules // evaluatedConfig.homeModules;
    inherit osUsernames hmUsernames;
  };

  buildHost = filename: type: let
    entry = parseHostEntry filename type;
    inherit (entry) isDir name path hostDir;
    evaluatedHost = validateHost path;
    cfg = evaluatedHost.config;
    autoModules = autoDiscoverModules isDir hostDir;
    enriched = enrichHost cfg autoModules;
    warnings = flakeLib.checkAdminWarning name cfg;
  in
    cfg
    // enriched
    // {inherit name;}
    // lib.optionalAttrs (warnings != []) {inherit warnings;};

  discoveredHosts = lib.mapAttrs buildHost hostEntries;

  # ── resolve overlays and pre-compute overlay-resolved pkgs for each host ──
  # This runs once here so that hostPackageSets and the configs use the
  # same pkgs/pkgsUnstable with the same overlays applied.
  hostsWithPkgs = lib.mapAttrs (_name: host: let
    overlays = flakeLib.resolveHostOverlays host;
  in
    host
    // {
      inherit overlays;
      pkgs = import inputs.nixpkgs {
        inherit (host) system;
        overlays = overlays.stable;
        config.allowUnfree = true;
      };
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (host) system;
        overlays = overlays.unstable;
        config.allowUnfree = true;
      };
    })
  discoveredHosts;
in {
  flake = {
    features = flakeLib.discoveredFeatures;

    nixosConfigurations = flakeLib.buildNixosConfigurations hostsWithPkgs;
    homeConfigurations = flakeLib.buildHomeConfigurations hostsWithPkgs;

    hostPackageSets =
      lib.mapAttrs (_: h: {
        inherit (h) pkgs pkgsUnstable;
      })
      hostsWithPkgs;
  };
}
