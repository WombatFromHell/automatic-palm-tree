{
  lib,
  inputs,
  self,
  hostsDir,
  systemModules,
  isDarwinPlatform,
  pkgsFor,
  pkgsUnstableFor,
}: let
  platformModule = system: name: {
    networking.hostName = lib.mkDefault name;
    nixpkgs.hostPlatform = lib.mkDefault system;
  };

  mkSystem = system: name: users: let
    darwin = isDarwinPlatform system;
    pkgsStable = pkgsFor system;
    pkgsUnstable = pkgsUnstableFor system;

    entry =
      if darwin
      then inputs.nix-darwin.lib.darwinSystem
      else inputs.nixpkgs.lib.nixosSystem;

    hmMod =
      lib.optional darwin
      inputs.home-manager-darwin.darwinModules.home-manager;

    nixpkgsMod =
      lib.optional darwin
      {nixpkgs.pkgs = pkgsStable;};

    hmCommon = {
      useGlobalPkgs = false; # false so HM can use its own pkgs (unstable)
      useUserPackages = true;
      extraSpecialArgs = {
        inherit self inputs pkgsStable pkgsUnstable;
        hostname = name;
      };
      users = lib.genAttrs users (
        user:
          import (hostsDir + "/${name}/home-${user}.nix")
      );
    };

    hmDefaults = lib.optional (darwin && users != []) {
      home-manager = hmCommon;
      users.users = lib.genAttrs users (user: {home = "/Users/${user}";});
    };
  in
    entry {
      inherit system;
      modules =
        systemModules
        ++ nixpkgsMod
        ++ hmMod
        ++ hmDefaults
        ++ [
          (hostsDir + "/${name}/system.nix")
          (platformModule system name)
        ];
      specialArgs = {
        inherit self inputs pkgsStable pkgsUnstable;
        username = lib.head users;
      };
    };
in {inherit mkSystem;}
