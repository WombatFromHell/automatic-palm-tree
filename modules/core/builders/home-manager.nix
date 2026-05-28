# modules/core/builders/home-manager.nix
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
in {
  imports = [../discovery.nix];

  flake.homeConfigurations =
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

        homeFeatures = featuresLib.resolve (host.features or []) "home";
        hostHmModules = (host.modules.home or []) ++ (host.modules.shared or []);
        hmOutputName = "${host.username}@${name}";
      in
        lib.nameValuePair hmOutputName (
          inputs.home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = lib.flatten [
              ../nix-settings.nix
              self.flakeModules.home-manager
              homeFeatures
              hostHmModules
              {
                _module.args.hostContext = hostContext;
                home.username = host.username;
                home.homeDirectory = "/home/${host.username}";

                # If isNixOS is false genericLinux must be enabled
                targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);
              }
            ];
            extraSpecialArgs = {
              inherit hostContext pkgsUnstable inputs self;
              pkgsStable = pkgs;
            };
          }
        )
    )
    hmHosts;
}
