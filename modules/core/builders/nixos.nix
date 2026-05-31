{
  lib,
  self,
  inputs,
  config,
  ...
}: let
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};

  nixosHosts = lib.filterAttrs (_: h: h.config.isNixOS or false) config.discoveredHosts;

  resolveNixosModules = hostModules:
    (hostModules.nixos or []) ++ (hostModules.shared or []);

  resolveHmModules = hostModules:
    (hostModules.home or []) ++ (hostModules.shared or []);

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
in {
  imports = [../discovery.nix];

  flake.nixosConfigurations =
    lib.mapAttrs' (
      filename: h: let
        inherit (h) name config;
        host = config;

        hostFeatures = host.features or [];
        nixosFeatures = lib.filter (f: (featuresLib.discoveredFeatures ? ${f}) && (featuresLib.discoveredFeatures.${f} ? nixos)) hostFeatures;
        homeFeatures = lib.filter (f: (featuresLib.discoveredFeatures ? ${f}) && (featuresLib.discoveredFeatures.${f} ? home)) hostFeatures;
        nixosFeaturesData = featuresLib.resolve nixosFeatures "nixos";
        homeFeaturesData = featuresLib.resolve homeFeatures "home";
        hostNixosModules = resolveNixosModules (host.modules or []);
        hostHmModules = resolveHmModules (host.modules or []);

        userModulePaths = featuresLib.resolveUserModules (self + /hosts) name host.usernames;

        userUnfreeExtraction = lib.evalModules {
          modules = userModulePaths ++ [unfreeOptionsModule {_module.check = false;}];
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

        allUnfree =
          (host.unfree or [])
          ++ nixosFeaturesData.unfree
          ++ homeFeaturesData.unfree
          ++ userUnfreeExtraction.config.unfree;
        allUnfreeUnstable =
          (host.unfreeUnstable or [])
          ++ nixosFeaturesData.unfreeUnstable
          ++ homeFeaturesData.unfreeUnstable
          ++ userUnfreeExtraction.config.unfreeUnstable;

        pkgsUnstable = pkgsLib.mkPkgsUnstable host.system allUnfreeUnstable;

        # -------------------------------------------------------
        # Grouped Module Definitions
        # -------------------------------------------------------

        # 1. Core NixOS configuration
        baseModule = {
          nixpkgs = {
            hostPlatform = host.system;
            config.allowUnfreePredicate = pkg:
              builtins.elem (lib.getName pkg) allUnfree;
          };
          # Make pkgsUnstable available as an argument to all NixOS modules
          _module.args = {inherit pkgsUnstable;};
        };

        # 2. Home Manager setup
        homeManagerModule = {
          nixpkgs.overlays = [
            inputs.nix-cachyos-kernel.overlays.default
          ];
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = {
              inherit pkgsUnstable inputs self;
            };
            users = lib.genAttrs host.usernames (
              user: let
                userModPath = self + /hosts/${name}/home-${user}.nix;
                userMod = lib.optional (builtins.pathExists userModPath) userModPath;
              in
                lib.mkMerge (
                  [
                    unfreeOptionsModule
                    self.flakeModules.home-manager
                    {
                      home.username = user;
                      home.homeDirectory = "/home/${user}";
                    }
                  ]
                  ++ homeFeaturesData.modules
                  ++ hostHmModules
                  ++ userMod
                )
            );
          };
        };
      in
        lib.nameValuePair name (
          inputs.nixpkgs.lib.nixosSystem {
            # The module list is now flat, clearly ordered, and easy to reason about
            modules = [
              unfreeOptionsModule
              ../nix-settings.nix
              baseModule
              self.flakeModules.nixos
              nixosFeaturesData.modules
              hostNixosModules
              inputs.home-manager.nixosModules.home-manager
              homeManagerModule
            ];
            specialArgs = {
              inherit inputs self;
              inherit (host) usernames;
              mkUser = {groups ? [], ...} @ args:
                (removeAttrs args ["groups"])
                // {
                  isNormalUser = true;
                  extraGroups = ["wheel" "networkmanager"] ++ groups;
                };
            };
          }
        )
    )
    nixosHosts;
}
