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

  # Declare the options so HM doesn't throw "unknown option" errors
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

  flake.homeConfigurations =
    lib.mapAttrs' (
      filename: h: let
        inherit (h) name config;
        host = config;

        homeFeaturesData = featuresLib.resolve (host.features or []) "home";
        hostHmModules = (host.modules.home or []) ++ (host.modules.shared or []);
        hmOutputName = "${host.username}@${name}";

        allUnfree = (host.unfree or []) ++ homeFeaturesData.unfree;
        allUnfreeUnstable = (host.unfreeUnstable or []) ++ homeFeaturesData.unfreeUnstable;

        hostPkgs = pkgsLib.mkHostPkgs host allUnfree allUnfreeUnstable;
        inherit (hostPkgs) system pkgs pkgsUnstable;

        hostContext = {
          inherit system;
          inherit (host) username;
          hostname = name;
          inherit pkgs pkgsUnstable inputs self;
        };
      in
        lib.nameValuePair hmOutputName (
          inputs.home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = lib.flatten [
              unfreeOptionsModule # <--- Injected here
              ../nix-settings.nix
              self.flakeModules.home-manager
              homeFeaturesData.modules
              hostHmModules
              {
                _module.args.hostContext = hostContext;
                home.username = host.username;
                home.homeDirectory = "/home/${host.username}";
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
