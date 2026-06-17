{
  self,
  lib,
  config,
  inputs,
  ...
}: let
  builders = import ../lib/builders.nix {inherit lib self inputs;};
in {
  imports = [./discovery.nix];

  flake = {
    hostPackageSets =
      lib.mapAttrs (_: h: {
        inherit (h) pkgsStable pkgsUnstable;
      })
      config.discoveredHosts;

    nixosConfigurations = builders.buildNixosConfigurations config.discoveredHosts;
    homeConfigurations = builders.buildHomeConfigurations config.discoveredHosts;
  };
}
