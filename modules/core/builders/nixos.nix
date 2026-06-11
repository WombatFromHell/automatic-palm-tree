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
    featuresLib
    resolveFeatures
    collectUnfree
    hostHmModules
    ;

  nixosHosts = lib.filterAttrs (_: h: h.config.isNixOS or false) config.discoveredHosts;

  hostNixosModules = host:
    lib.flatten [
      (host.modules.nixos or [])
      (host.modules.shared or [])
    ];

  mkNixosConfig = name: h: let
    host = h.config;
    hostConfig = host;

    nixosFeaturesData = resolveFeatures host "nixos";
    homeFeaturesData = resolveFeatures host "home";

    userModulePaths = lib.concatLists (lib.attrValues (host.modules.perUser or {}));
    allUnfree = collectUnfree host [nixosFeaturesData homeFeaturesData] userModulePaths;
    pkgsUnstable = pkgsLib.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];

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
          inherit
            pkgsUnstable
            inputs
            self
            hostConfig
            ;
        };

        users = lib.genAttrs host.usernames (user: {
          imports = lib.flatten [
            homeFeaturesData.modules
            (hostHmModules host)
            (host.modules.perUser.${user} or [])
            pkgsLib.mkUnfreeOptionsModule
            self.flakeModules.home-manager
            {
              home.username = user;
              home.homeDirectory = "/home/${user}";
            }
          ];
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
        (lib.optional (!host.bootstrap) inputs.determinate.nixosModules.default)
        (hostNixosModules host)
        inputs.home-manager.nixosModules.home-manager
        homeManagerModule
      ];

      specialArgs = {
        inherit inputs self;
        inherit (host) usernames;
        mkUser = username: {groups ? [], ...} @ args:
          let
            isAdmin = host.users.${username}.isAdmin or false;
          in {
            isNormalUser = true;
            extraGroups = ["networkmanager"]
              ++ lib.optional isAdmin "wheel"
              ++ groups;
          } // removeAttrs args ["groups"];
      };
    };
in {
  imports = [../discovery.nix];
  flake.nixosConfigurations = lib.mapAttrs mkNixosConfig nixosHosts;
}
