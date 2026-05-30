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
          modules = userModulePaths ++ [unfreeOptionsModule];
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

        # Build pkgsUnstable here — NixOS owns stable pkgs via nixpkgs.* options
        pkgsUnstable = pkgsLib.mkPkgsUnstable host.system allUnfreeUnstable;
      in
        lib.nameValuePair name (
          inputs.nixpkgs.lib.nixosSystem {
            modules = lib.flatten [
              unfreeOptionsModule
              ../nix-settings.nix
              # Let NixOS own pkgs — no specialArgs.pkgs needed
              {
                nixpkgs.hostPlatform = host.system;
                nixpkgs.config.allowUnfreePredicate = pkg:
                  builtins.elem (lib.getName pkg) allUnfree;
              }
              self.flakeModules.nixos
              nixosFeaturesData.modules
              hostNixosModules
              inputs.home-manager.nixosModules.home-manager
              {
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
                        [unfreeOptionsModule self.flakeModules.home-manager]
                        ++ homeFeaturesData.modules
                        ++ hostHmModules
                        ++ userMod
                        ++ [
                          {
                            home.username = user;
                            home.homeDirectory = "/home/${user}";
                          }
                        ]
                      )
                  );
                };
              }
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
