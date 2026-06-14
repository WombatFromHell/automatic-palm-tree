{
  self,
  lib,
  ...
}: let
  # Export discovered features to flake outputs for inspection and reuse.
  featuresLib = import ../lib/features.nix {inherit self lib;};
in {
  imports = [
    # Builders: flake-parts modules that produce nixosConfigurations
    # and homeConfigurations from the discovered host schema.
    ./builders/nixos.nix
    ./builders/home-manager.nix
  ];

  # Expose reusable modules so builders reference them by flake path
  # rather than fragile relative paths.
  flake.flakeModules = {
    nixos = self + /modules/nixos.nix;
    home-manager = self + /modules/home-manager.nix;
    nix-settings = self + /modules/nix-settings.nix;
    # NOTE: for downstream flakes only. Internal builders cannot use this because
    # `self` is not yet finalised when `imports` are resolved.
    discovery = self + /modules/discovery.nix;
  };

  # Expose the auto-discovered features to the flake outputs
  # (visible in `nix flake show`, usable by other flakes).
  flake.features = featuresLib.discoveredFeatures;
}
