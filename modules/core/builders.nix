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

  isDarwin = lib.hasSuffix "darwin";

  mkSystem = system: name: users: let
    darwin = isDarwin system;
    entry =
      if darwin
      then inputs.nix-darwin.lib.darwinSystem
      else inputs.nixpkgs.lib.nixosSystem;

    hmMod =
      lib.optional darwin
      inputs.home-manager.darwinModules.home-manager;

    hmDefaults = lib.optional (darwin && users != []) {
      home-manager = {
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
      # Set per-user home directories directly as nix-darwin options
      users.users = lib.genAttrs users (user: {
        home = "/Users/${user}";
      });
    };
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
              if isDarwin system
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
      sys = host.platform;
      darwin = isDarwin sys;
    in {
      nixos =
        acc.nixos
        // lib.optionalAttrs (host.hasSystem && !darwin)
        {${name} = mkSystem sys name host.users;};
      darwin =
        acc.darwin
        // lib.optionalAttrs (host.hasSystem && darwin)
        {${name} = mkSystem sys name host.users;};
      home =
        acc.home
        // lib.listToAttrs (map (user: {
            name = "${user}@${name}";
            value = mkHome sys name user;
          })
          host.users);
    }) {
      nixos = {};
      darwin = {};
      home = {};
    }
    discoverHosts;
in {inherit mkSystem mkHome buildConfigs;}
