{
  self,
  lib,
  inputs,
  ...
}: let
  pkgsLib = import ./pkgs.nix {inherit lib;};
  featuresLib = import ./features.nix {inherit self lib pkgsLib;};
in {
  imports = [
    ./builders/nixos.nix
    ./builders/home-manager.nix
  ];

  # Expose the auto-discovered features to the flake outputs
  # (This makes them visible in `nix flake show` and usable by other flakes)
  flake.features = featuresLib.discoveredFeatures;
}
