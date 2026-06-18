{
  self,
  lib,
  config,
  inputs,
  ...
}: let
  featuresLib = import ../lib/features.nix {inherit self lib;};
  builders = import ../lib/builders.nix {inherit lib self inputs featuresLib;};

  # Single instantiation of pkgsUnstable per host — consumed by builders
  # and hostPackageSets alike. pkgs (stable) is intentionally not unified
  # here: NixOS hosts build it internally via nixosSystem (overlays come
  # from config.overlays inside the module eval); HM-only hosts build it
  # after overlay resolution in builders.nix.
  hostsWithPkgs = lib.mapAttrs (_: h:
    h
    // {
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (h) system;
        config.allowUnfree = true;
      };
    })
  config.discoveredHosts;
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

    nixosConfigurations = builders.buildNixosConfigurations hostsWithPkgs;
    homeConfigurations = builders.buildHomeConfigurations hostsWithPkgs;
  };

  flake.hostPackageSets =
    lib.mapAttrs (_: h: {
      pkgs = import inputs.nixpkgs {
        inherit (h) system;
        config.allowUnfree = true;
      };
      inherit (h) pkgsUnstable;
    })
    hostsWithPkgs;
}
