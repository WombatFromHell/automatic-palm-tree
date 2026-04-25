{
  lib,
  inputs,
  self,
  hostsDir,
  systemModules,
  isDarwinPlatform,
}: let
  platformModule = system: name: {
    networking.hostName = lib.mkDefault name;
    nixpkgs.hostPlatform = lib.mkDefault system;
  };

  mkSystem = system: name: users: let
    darwin = isDarwinPlatform system;
    entry =
      if darwin
      then inputs.nix-darwin.lib.darwinSystem
      else inputs.nixpkgs.lib.nixosSystem;

    hmMod =
      lib.optional darwin
      inputs.home-manager.darwinModules.home-manager;

    hmCommon = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = {
        inherit self inputs;
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
        ++ hmMod
        ++ hmDefaults
        ++ [
          (hostsDir + "/${name}/system.nix")
          (platformModule system name)
        ];
      specialArgs = {
        inherit self inputs;
        username = lib.head users;
      };
    };
in {inherit mkSystem;}
