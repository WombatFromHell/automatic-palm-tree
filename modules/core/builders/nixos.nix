# modules/core/builders/nixos.nix
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
in {
  imports = [../discovery.nix];

  flake.nixosConfigurations =
    lib.mapAttrs' (
      filename: h: let
        inherit (h) name config;
        host = config;

        hostPkgs = pkgsLib.mkHostPkgs host;
        inherit (hostPkgs) system pkgs pkgsUnstable;

        hostContext = {
          inherit system;
          inherit (host) username;
          hostname = name;
          inherit pkgs pkgsUnstable inputs self;
        };

        nixosFeatures = featuresLib.resolve (host.features or []) "nixos";
        homeFeatures = featuresLib.resolve (host.features or []) "home";
        hostNixosModules = resolveNixosModules (host.modules or []);
        hostHmModules = resolveHmModules (host.modules or []);
      in
        lib.nameValuePair name (
          inputs.nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = lib.flatten [
              ../nix-settings.nix
              self.flakeModules.nixos
              nixosFeatures
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
                    [self.flakeModules.home-manager]
                    ++ homeFeatures
                    ++ hostHmModules
                    # Explicitly ensure genericLinux is disabled for NixOS hosts
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
