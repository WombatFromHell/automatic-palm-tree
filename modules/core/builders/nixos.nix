{
  lib,
  self,
  inputs,
  ...
}: let
  discovery = import ../discovery.nix {inherit lib self inputs;};
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};

  nixosHosts = lib.filterAttrs (_: h: h.config.isNixOS or false) discovery;
in {
  flake.nixosConfigurations =
    lib.mapAttrs' (
      filename: h: let
        inherit (h) name config;
        host = config;

        # CHANGED: one call replaces the four separate lines
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
      in
        lib.nameValuePair name (
          inputs.nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = lib.flatten [
              ../nix-settings.nix
              self.flakeModules.nixos
              nixosFeatures
              ({config, ...}: {
                _module.args.hostContext = hostContext;
                imports = [(host.nixos or {})];
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
                    ++ [(host.home or {})]
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
