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

        nixosFeaturesData = featuresLib.resolve (host.features or []) "nixos";
        homeFeaturesData = featuresLib.resolve (host.features or []) "home";
        hostNixosModules = resolveNixosModules (host.modules or []);
        hostHmModules = resolveHmModules (host.modules or []);

        allUnfree = (host.unfree or []) ++ nixosFeaturesData.unfree ++ homeFeaturesData.unfree;
        allUnfreeUnstable = (host.unfreeUnstable or []) ++ nixosFeaturesData.unfreeUnstable ++ homeFeaturesData.unfreeUnstable;

        hostPkgs = pkgsLib.mkHostPkgs host allUnfree allUnfreeUnstable;
        inherit (hostPkgs) system pkgs pkgsUnstable;

        hostContext = {
          inherit system;
          inherit (host) username;
          hostname = name;
          inherit pkgs pkgsUnstable inputs self;
        };
      in
        lib.nameValuePair name (
          inputs.nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = lib.flatten [
              unfreeOptionsModule # <--- For NixOS system modules
              ../nix-settings.nix
              self.flakeModules.nixos
              nixosFeaturesData.modules
              hostNixosModules
              ({config, ...}: {
                _module.args.hostContext = hostContext;
              })
              inputs.home-manager.nixosModules.home-manager
              {
                home-manager = {
                  useGlobalPkgs = true;
                  useUserPackages = true;
                  extraSpecialArgs = {
                    inherit hostContext pkgsUnstable inputs self;
                    pkgsStable = pkgs;
                  };
                  users.${host.username} = lib.mkMerge (
                    [
                      unfreeOptionsModule # <--- For HM user modules
                      self.flakeModules.home-manager
                    ]
                    ++ homeFeaturesData.modules
                    ++ hostHmModules
                    ++ [{targets.genericLinux.enable = lib.mkDefault false;}]
                  );
                };
              }
            ];
            specialArgs = {
              inherit hostContext;
              inherit (host) username;
            };
          }
        )
    )
    nixosHosts;
}
