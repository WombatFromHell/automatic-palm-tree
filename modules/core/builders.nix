{
  lib,
  inputs,
  self,
  hostsDir,
  coreModules,
}: let
  pkgsFor = system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

  platformModule = system: name: {
    networking.hostName = lib.mkDefault name;
    nixpkgs.hostPlatform = lib.mkDefault system;
  };

  isDarwinPlatform = lib.hasSuffix "darwin";

  mkSystem = system: name: users: let
    darwin = isDarwinPlatform system;
    entry =
      if darwin
      then inputs.nix-darwin.lib.darwinSystem
      else inputs.nixpkgs.lib.nixosSystem;

    hmMod =
      if darwin
      then [inputs.home-manager.darwinModules.home-manager]
      else [inputs.home-manager.nixosModules.home-manager];

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

    hmDarwinDefaults = lib.optionalAttrs (darwin && users != []) {
      users.users = lib.genAttrs users (user: {
        home = "/Users/${user}";
      });
    };

    hmDefaults = lib.optional (users != []) (
      {home-manager = hmCommon;} // hmDarwinDefaults
    );
  in
    entry {
      inherit system;
      modules =
        coreModules
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

  mkHome = system: name: user: let
    pkgs = pkgsFor system;
  in
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules =
        coreModules
        ++ [
          (hostsDir + "/${name}/home-${user}.nix")
          {
            home.username = lib.mkDefault user;
            home.homeDirectory = lib.mkDefault (
              if isDarwinPlatform system
              then "/Users/${user}"
              else "/home/${user}"
            );
            nixpkgs.system = lib.mkDefault system;
            nix.package = pkgs.nix;
          }
        ];
      extraSpecialArgs = {
        inherit self inputs;
        hostname = name;
      };
    };

  buildConfigs = discoverHosts:
    lib.foldlAttrs (acc: name: host: let
      inherit (host) system;
      darwin = isDarwinPlatform system;
    in {
      nixos =
        acc.nixos
        // lib.optionalAttrs (host.hasSystem && !darwin)
        {${name} = mkSystem system name host.users;};
      darwin =
        acc.darwin
        // lib.optionalAttrs (host.hasSystem && darwin)
        {${name} = mkSystem system name host.users;};
      home =
        acc.home
        // lib.listToAttrs (map (user: {
            name = "${user}@${name}";
            value = mkHome system name user;
          })
          host.users);
    }) {
      nixos = {};
      darwin = {};
      home = {};
    }
    discoverHosts;
in {inherit mkSystem mkHome buildConfigs;}
