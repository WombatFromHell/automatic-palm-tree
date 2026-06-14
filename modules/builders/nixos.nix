# modules/builders/nixos.nix
{
  self,
  lib,
  config,
  inputs,
  ...
}: let
  builderHelpers = import ../../lib/builder-helpers.nix {inherit lib self;};
  pkgsLib = import ../../lib/pkgs.nix {inherit lib;};

  nixosHosts = lib.filterAttrs (_: h: h.isNixOS or false) config.discoveredHosts;

  mkNixosConfig = _: host: let
    baseModule = {pkgs, ...}: {
      imports = lib.flatten host.nixosModules;
      boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
      nixpkgs = {
        hostPlatform = host.system;
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) host.allUnfree;
      };
      _module.args = {
        inherit (host) pkgsUnstable isNixOS;
        hostConfig = host;
      };
    };

    homeManagerModule = {config, ...}: {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = {
          pkgsUnstable = config.nixpkgs.pkgs.pkgsUnstable or host.pkgsUnstable;
          inherit inputs self host;
          hostConfig = host;
        };

        users = lib.genAttrs host.hmUsernames (user:
          builderHelpers.mkUserHomeModule {
            ctx = host;
            inherit user host;
          });
      };
    };

    hostModules = builderHelpers.resolveHostModules host "nixos";
  in
    inputs.nixpkgs.lib.nixosSystem {
      modules = lib.flatten [
        pkgsLib.mkUnfreeOptionsModule
        self.flakeModules.nix-settings
        baseModule
        self.flakeModules.nixos
        (builderHelpers.mkNixosUserModule host)
        hostModules
        inputs.home-manager.nixosModules.home-manager
        homeManagerModule
      ];

      specialArgs = {
        inherit inputs self;
        inherit (host) osUsernames hmUsernames bootstrap;
        hostConfig = host;
      };
    };
in {
  imports = [../discovery.nix];

  # Expose pre-built package sets for downstream consumption
  # (dev shells, CI checks, etc.).
  flake.hostPackageSets =
    lib.mapAttrs (_: h: {
      inherit (h) pkgsStable pkgsUnstable;
    })
    config.discoveredHosts;

  flake.nixosConfigurations = lib.mapAttrs mkNixosConfig nixosHosts;
}
