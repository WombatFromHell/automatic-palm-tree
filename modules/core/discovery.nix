# modules/core/discovery.nix
{
  lib,
  self,
  inputs,
  ...
}: let
  hostsDir = self + /hosts;
  entries = builtins.readDir hostsDir;

  hostEntries =
    lib.filterAttrs (
      n: t:
        (t == "regular" && lib.hasSuffix ".nix" n)
        || (t == "directory" && builtins.pathExists (hostsDir + "/${n}/default.nix"))
    )
    entries;

  # ── Auto-discover modules in a host directory ────────────────
  autoDiscoverModules = isDir: hostDir:
    if !isDir
    then {
      nixos = [];
      shared = [];
      perUser = {};
    }
    else {
      nixos =
        lib.optional (builtins.pathExists (hostDir + "/nixos.nix"))
        (hostDir + "/nixos.nix");
      shared =
        lib.optional (builtins.pathExists (hostDir + "/shared.nix"))
        (hostDir + "/shared.nix");
      perUser = let
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
in {
  options.discoveredHosts = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    internal = true;
    default = {};
  };

  config.discoveredHosts =
    lib.mapAttrs (
      filename: type: let
        isDir = type == "directory";
        name =
          if isDir
          then filename
          else lib.removeSuffix ".nix" filename;
        path =
          if isDir
          then hostsDir + "/${filename}/default.nix"
          else hostsDir + "/${filename}";

        # 1. Import the raw host file
        rawHostConfig = import path {inherit self inputs lib;};

        # 2. Extract the modules block so evalModules doesn't choke on it
        hostModules = rawHostConfig.modules or {};

        # 3. Remove it from the config before strict validation
        safeConfig = builtins.removeAttrs rawHostConfig ["modules"];

        # 4. Evaluate the safe config against the strict schema
        evaluatedHost = lib.evalModules {
          modules = [
            ./host-schema.nix
            safeConfig
          ];
        };

        # 5. Auto-discover modules in the host directory
        hostDir =
          if isDir
          then hostsDir + "/${filename}"
          else null;

        autoModules = autoDiscoverModules isDir hostDir;

        # 6. Per-user home modules from modules.home.<user>
        perUserFromHome = hostModules.home or {};

        # 7. Derive usernames from all sources
        allUsernames = lib.unique (
          (builtins.attrNames autoModules.perUser)
          ++ (builtins.attrNames perUserFromHome)
        );
        impliedUsers = builtins.listToAttrs (
          map (user: {
            name = user;
            value = {enabled = true;};
          })
          allUsernames
        );
        mergedUsers = lib.recursiveUpdate impliedUsers (evaluatedHost.config.users or {});
        enabledUsers = lib.filterAttrs (_: u: u.enabled) mergedUsers;
        osUsernames = lib.attrNames enabledUsers;
        hmUsernames =
          builtins.filter (
            u: builtins.elem u allUsernames && (mergedUsers.${u}.hmEnabled or true)
          )
          osUsernames;

        # 8. Merge auto-discovered with explicitly defined modules
        mergedModules = {
          nixos = autoModules.nixos ++ (hostModules.nixos  or []);
          shared = autoModules.shared ++ (hostModules.shared or []);
          perUser = lib.recursiveUpdate autoModules.perUser perUserFromHome;
        };
      in {
        inherit name;
        config =
          evaluatedHost.config
          // {
            modules = mergedModules;
            inherit osUsernames hmUsernames mergedUsers;
            features = evaluatedHost.config.features or [];
          };
      }
    )
    hostEntries;
}
