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

  mkSystem = system: name: let
    darwin = isDarwin system;
    entry =
      if darwin
      then inputs.nix-darwin.lib.darwinSystem
      else inputs.nixpkgs.lib.nixosSystem;
    hmMod =
      lib.optional darwin
      inputs.home-manager.darwinModules.home-manager;
  in
    entry {
      inherit system;
      modules =
        coreModules
        ++ hmMod
        ++ [
          (hostsDir + "/${name}/system.nix")
          (platformModule system name)
        ];
      specialArgs = {inherit self inputs;};
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
    in {
      nixos =
        acc.nixos
        // lib.optionalAttrs (host.hasSystem && !isDarwin sys)
        {${name} = mkSystem sys name;};
      darwin =
        acc.darwin
        // lib.optionalAttrs (host.hasSystem && isDarwin sys)
        {${name} = mkSystem sys name;};
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
