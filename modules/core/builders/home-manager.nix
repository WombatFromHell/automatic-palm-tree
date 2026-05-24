{
  lib,
  self,
  inputs,
  ...
}: let
  discovery = import ../discovery.nix {inherit lib self inputs;};
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};

  # Filter strictly for Standalone Home Manager hosts
  # Note: changed `or true` to `or false` so HM is the default if omitted
  hmHosts = lib.filterAttrs (_: h: !(h.config.isNixOS or false)) discovery;
in {
  flake.homeConfigurations =
    lib.mapAttrs' (
      filename: h: let
        inherit (h) name config;
        host = config;

        # 1. Extract attributes and apply defaults safely
        system = host.system or "x86_64-linux";
        unfreeStable = host.unfreeStable or [];
        unfreeUnstable = host.unfreeUnstable or [];

        pkgs = pkgsLib.mkPkgs system unfreeStable;
        pkgsUnstable = pkgsLib.mkPkgsUnstable system unfreeUnstable;

        hostContext = {
          # 2. Inherit from the local scope
          inherit system unfreeStable unfreeUnstable;
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
