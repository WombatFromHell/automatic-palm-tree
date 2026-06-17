{
  lib,
  self,
  inputs,
}: let
  builderHelpers = import ./builder-helpers.nix {inherit lib self;};
  featuresLib = import ./features.nix {inherit lib self;};
in {
  buildNixosConfigurations = discoveredHosts: let
    nixosHosts = lib.filterAttrs (_: h: h.isNixOS or false) discoveredHosts;
    mkNixosConfig = _name: host: let
      baseModule = {pkgs, ...}: {
        imports = lib.flatten host.nixosModules;
        boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
        nixpkgs = {
          hostPlatform = host.system;
          config.allowUnfreePredicate = let
            u = builtins.listToAttrs (map (n: {
                name = n;
                value = true;
              })
              host.allUnfree);
          in
            pkg: u ? ${lib.getName pkg};
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
          users =
            lib.genAttrs host.hmUsernames (user:
              builderHelpers.mkUserHomeModule {inherit user host;});
        };
      };

      hostModules = builderHelpers.resolveHostModules host "nixos";
    in
      inputs.nixpkgs.lib.nixosSystem {
        modules = lib.flatten [
          featuresLib.featureOptionsModule
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
  in
    lib.mapAttrs mkNixosConfig nixosHosts;

  buildHomeConfigurations = discoveredHosts: let
    hmHosts = lib.filterAttrs (_: h: !(h.isNixOS or false)) discoveredHosts;
    mkHomeConfig = host: user: let
      inherit (host) pkgsStable;
      baseModule = {
        imports = [
          (builderHelpers.mkUserHomeModule {inherit user host;})
          {targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);}
        ];
      };
    in
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsStable;
        modules = [self.flakeModules.nix-settings baseModule];
        extraSpecialArgs = {
          inherit pkgsStable;
          inherit (host) pkgsUnstable;
          inherit inputs self;
          hostConfig = host;
        };
      };
  in
    builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList
      (_: hostEntry:
        map (user:
          lib.nameValuePair "${user}@${hostEntry.name}"
          (mkHomeConfig hostEntry user))
        hostEntry.hmUsernames)
      hmHosts));
}
