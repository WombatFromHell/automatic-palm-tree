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

  hmHosts = lib.filterAttrs (_: h: !(h.config.isNixOS or false)) discovery;

  # Extract modules tagged for home-manager or shared
  resolveHmModules = hostModules:
    lib.pipe hostModules [
      (lib.filter (m: m.platform == "home" || m.platform == "shared"))
      (map (m: m.module))
    ];
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
        hostHmModules = resolveHmModules (host.modules or []);
        hmOutputName = "${host.username}@${name}";
      in
        lib.nameValuePair hmOutputName (
          inputs.home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = lib.flatten [
              ../nix-settings.nix
              self.flakeModules.home-manager
              homeFeatures
              hostHmModules # replaces (host.home or {})
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
