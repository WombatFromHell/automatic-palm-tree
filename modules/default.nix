{
  self,
  lib,
  config,
  inputs,
  ...
}: let
  featuresLib = import ../lib/features.nix {inherit self lib;};
  builders = import ../lib/builders.nix {inherit lib self inputs;};
in {
  imports = [./discovery.nix];

  flake = {
    flakeModules = {
      nixos = self + /modules/nixos.nix;
      home-manager = self + /modules/home-manager.nix;
      nix-settings = self + /modules/nix-settings.nix;
      discovery = self + /modules/discovery.nix;
    };

    features = featuresLib.discoveredFeatures;

    # Builders are now pure functions wired directly to flake outputs
    nixosConfigurations = builders.buildNixosConfigurations config.discoveredHosts;
    homeConfigurations = builders.buildHomeConfigurations config.discoveredHosts;
  };
  flake.hostPackageSets =
    lib.mapAttrs (_: h: {
      inherit (h) pkgsStable pkgsUnstable;
    })
    config.discoveredHosts;
}
