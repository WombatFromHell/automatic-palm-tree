{
  lib,
  self,
  inputs,
  ...
}: let
  discovery = import ../discovery.nix {inherit lib self inputs;};
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};

  hmHosts = lib.filterAttrs (_: h: !(h.config.isNixOS or false)) discovery;
in {
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
        hmOutputName = "${host.username}@${name}";
      in
        lib.nameValuePair hmOutputName (
          inputs.home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = lib.flatten [
              ../nix-settings.nix
              self.flakeModules.home-manager
              homeFeatures
              (host.home or {})
              {
                _module.args.hostContext = hostContext;
                home.username = host.username;
                home.homeDirectory = "/home/${host.username}";
                targets.genericLinux.enable = true;
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
