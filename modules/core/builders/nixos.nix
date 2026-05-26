{
  lib,
  self,
  inputs,
  ...
}: let
  hostLib = import ../host-lib.nix;
  discovery = import ../discovery.nix {inherit lib self inputs hostLib;};
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};

  nixosHosts = lib.filterAttrs (_: h: h.config.isNixOS or false) discovery;

  # Extract modules tagged for nixos or shared
  resolveNixosModules = hostModules:
    lib.pipe hostModules [
      (lib.filter (m: m.platform == "nixos" || m.platform == "shared"))
      (map (m: m.module))
    ];

  # Extract modules tagged for home-manager or shared
  resolveHmModules = hostModules:
    lib.pipe hostModules [
      (lib.filter (m: m.platform == "home" || m.platform == "shared"))
      (map (m: m.module))
    ];
in {
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
              hostNixosModules # replaces (host.nixos or {})
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
                    ++ hostHmModules # replaces (host.home or {})
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
