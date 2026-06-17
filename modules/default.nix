{
  self,
  lib,
  ...
}: let
  featuresLib = import ../lib/features.nix {inherit self lib;};
in {
  imports = [./builders.nix];

  flake.flakeModules = {
    nixos = self + /modules/nixos.nix;
    home-manager = self + /modules/home-manager.nix;
    nix-settings = self + /modules/nix-settings.nix;
    discovery = self + /modules/discovery.nix;
  };

  flake.features = featuresLib.discoveredFeatures;
}
