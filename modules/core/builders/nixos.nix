{
  self,
  lib,
  inputs,
  config,
  ...
}: let
  shared = import ./shared.nix {inherit lib self inputs;};
  inherit
    (shared)
    pkgsLib
    resolveFeatures
    collectUnfree
    hostHmModules
    mkUnstablePkgs
    perUserModulePaths
    mkUserHomeModule
    ;

  mkNixosUserModule = host: {lib, ...}: {
    users.users = lib.genAttrs host.osUsernames (username: let
      userCfg = host.users.${username} or {};
    in {
      isNormalUser = true;
      home = "/home/${username}";
      extraGroups =
        ["networkmanager"]
        ++ lib.optional (userCfg.isAdmin or false) "wheel";
    });
  };

  nixosHosts = lib.filterAttrs (_: h: h.config.isNixOS or false) config.discoveredHosts;

  hostNixosModules = host:
    lib.flatten [
      (host.modules.nixos or [])
      (host.modules.shared or [])
    ];

  mkNixosConfig = _: h: let
    host = h.config;

    nixosFeaturesData = resolveFeatures host "nixos";
    homeFeaturesData = resolveFeatures host "home";

    userModulePaths = perUserModulePaths host;
    allUnfree = collectUnfree host [nixosFeaturesData homeFeaturesData] userModulePaths;
    pkgsUnstable = mkUnstablePkgs host allUnfree;

    baseModule = {
      imports = lib.flatten nixosFeaturesData.modules;
      nixpkgs = {
        hostPlatform = host.system;
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allUnfree;
        overlays = [inputs.nix-cachyos-kernel.overlays.default];
      };
      _module.args = {
        inherit pkgsUnstable;
        hostConfig = host;
      };
    };

    homeManagerModule = {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = {
          inherit pkgsUnstable inputs self;
          hostConfig = host;
        };

        users = lib.genAttrs host.hmUsernames (user:
          mkUserHomeModule {
            inherit lib pkgsLib self user homeFeaturesData;
            hostHmModules = hostHmModules host;
            perUserMod = host.modules.perUser.${user} or [];
          });
      };
    };
  in
    inputs.nixpkgs.lib.nixosSystem {
      modules = lib.flatten [
        pkgsLib.mkUnfreeOptionsModule
        ../nix-settings.nix
        baseModule
        self.flakeModules.nixos
        (mkNixosUserModule host)
        (lib.optional (!host.bootstrap) inputs.determinate.nixosModules.default)
        (hostNixosModules host)
        inputs.home-manager.nixosModules.home-manager
        homeManagerModule
      ];

      specialArgs = {
        inherit inputs self;
        inherit (host) osUsernames hmUsernames;
        mkUser = username: {groups ? [], ...} @ args: let
          isAdmin = host.users.${username}.isAdmin or false;
        in
          {
            isNormalUser = true;
            extraGroups =
              ["networkmanager"]
              ++ lib.optional isAdmin "wheel"
              ++ groups;
          }
          // removeAttrs args ["groups"];
      };
    };
in {
  imports = [../discovery.nix];
  flake.nixosConfigurations = lib.mapAttrs mkNixosConfig nixosHosts;
}
