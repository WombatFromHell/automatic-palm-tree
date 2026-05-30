{
  lib,
  self,
  inputs,
  config,
  ...
}: let
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};

  hmHosts = lib.filterAttrs (_: h: !(h.config.isNixOS or false)) config.discoveredHosts;

  # Declare the options so HM doesn't throw "unknown option" errors
  unfreeOptionsModule = {
    options = {
      unfree = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        internal = true;
      };
      unfreeUnstable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        internal = true;
      };
    };
  };

  # Build home configurations for all non-NixOS hosts
  allHomeConfigs = lib.foldl' lib.recursiveUpdate {} (
    lib.mapAttrsToList (
      hostname: h: let
        inherit (h) name config;
        host = config;

        # Only resolve features that actually have modules for the requested platform
        hostFeatures = host.features or [];
        homeFeatures = lib.filter (f: (featuresLib.discoveredFeatures ? ${f}) && (featuresLib.discoveredFeatures.${f} ? home)) hostFeatures;
        homeFeaturesData = featuresLib.resolve homeFeatures "home";
        hostHmModules = (host.modules.home or []) ++ (host.modules.shared or []);

        # Discover per-user home module paths for the dry unfree-extraction pass
        userModulePaths = featuresLib.resolveUserModules (self + /hosts) hostname host.usernames;

        # Dry eval to extract unfree lists from per-user modules too
        userUnfreeExtraction = lib.evalModules {
          modules =
            userModulePaths
            ++ [
              {
                options = {
                  unfree = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [];
                    internal = true;
                  };
                  unfreeUnstable = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [];
                    internal = true;
                  };
                };
              }
            ];
          specialArgs = {
            pkgs = throw "pkgs cannot be used to define 'unfree' lists due to circular dependency.";
            pkgsUnstable = throw "pkgsUnstable cannot be used to define 'unfreeUnstable' lists due to circular dependency.";
            inherit lib;
            config = {};
            options = {};
            inputs = {};
            self = {};
          };
        };

        # Final unfree lists including per-user module contributions
        allUnfree =
          (host.unfree or [])
          ++ homeFeaturesData.unfree
          ++ userUnfreeExtraction.config.unfree;
        allUnfreeUnstable =
          (host.unfreeUnstable or [])
          ++ homeFeaturesData.unfreeUnstable
          ++ userUnfreeExtraction.config.unfreeUnstable;

        pkgs = pkgsLib.mkPkgs host.system allUnfree;
        pkgsUnstable = pkgsLib.mkPkgsUnstable host.system allUnfreeUnstable;
      in
        lib.listToAttrs (
          map (
            user: let
              userModPath = self + /hosts/${hostname}/home-${user}.nix;
              userMod = lib.optional (builtins.pathExists userModPath) userModPath;
              hmOutputName = "${user}@${name}";
            in
              lib.nameValuePair hmOutputName (
                inputs.home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = lib.flatten [
                    unfreeOptionsModule
                    ../nix-settings.nix
                    self.flakeModules.home-manager
                    homeFeaturesData.modules
                    hostHmModules
                    userMod
                    {
                      home.username = user;
                      home.homeDirectory = "/home/${user}";
                      targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);
                    }
                  ];
                  extraSpecialArgs = {
                    inherit pkgsUnstable inputs self;
                    inherit (host) usernames;
                    pkgsStable = pkgs;
                  };
                }
              )
          )
          host.usernames
        )
    )
    hmHosts
  );
in {
  imports = [../discovery.nix];

  flake.homeConfigurations = allHomeConfigs;
}
