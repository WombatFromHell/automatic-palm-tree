{
  lib,
  inputs,
  self,
  hostsDir,
  coreModule,
  mkPkgs ? system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
    },
}: let
  isDarwin = sys: lib.hasSuffix "darwin" sys;

  # Standard NixOS/Darwin platform assignment
  mkPlatformModule = system: name: {
    networking.hostName = lib.mkDefault name;
    nixpkgs.hostPlatform = lib.mkDefault system;
  };

  mkNixos = system: name:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        coreModule
        (import (hostsDir + "/${name}/system.nix")).module
        (mkPlatformModule system name)
      ];
      specialArgs = {inherit self inputs;};
    };

  mkDarwin = system: name:
    inputs.nix-darwin.lib.darwinSystem {
      inherit system;
      modules = [
        coreModule
        (import (hostsDir + "/${name}/system.nix")).module
        inputs.home-manager.darwinModules.home-manager
        (mkPlatformModule system name)
      ];
      specialArgs = {inherit self inputs;};
    };

  mkHome = system: name: user:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = mkPkgs system;
      modules = [
        coreModule
        (hostsDir + "/${name}/home-${user}.nix")
        {
          home.username = user;
          nixpkgs.system = lib.mkDefault system;
          nix.package = (mkPkgs system).nix;
        }
      ];
      extraSpecialArgs = {
        inherit self inputs;
        hostname = name;
      };
    };

  buildAllConfigs = discoverHosts: supportedSystems: let
    filterBySystem = system:
      lib.filterAttrs (_: h: h.platform == system) discoverHosts;

    partitionHosts = hosts: {
      systemHosts = lib.filterAttrs (_: h: h.hasSystem) hosts;
      homeHosts = lib.filterAttrs (_: h: h.users != []) hosts;
    };

    buildHomes = system:
      lib.foldlAttrs (
        acc: name: h:
          acc
          // builtins.listToAttrs (map (user: {
              name = "${user}@${name}";
              value = mkHome system name user;
            })
            h.users)
      ) {};
  in
    lib.foldl (acc: system: let
      partitioned = partitionHosts (filterBySystem system);
    in {
      nixos =
        acc.nixos
        // lib.optionalAttrs (!isDarwin system)
        (lib.mapAttrs (name: _: mkNixos system name) partitioned.systemHosts);

      darwin =
        acc.darwin
        // lib.optionalAttrs (isDarwin system)
        (lib.mapAttrs (name: _: mkDarwin system name) partitioned.systemHosts);

      home = acc.home // buildHomes system partitioned.homeHosts;
    }) {
      nixos = {};
      darwin = {};
      home = {};
    }
    supportedSystems;

  autoDefault = homeConfigs: discoverHosts: let
    hostname = builtins.getEnv "HOSTNAME";
    username = builtins.getEnv "USER";
    key = "${username}@${hostname}";
  in
    if
      hostname
      != ""
      && username != ""
      && discoverHosts ? ${hostname}
      && lib.elem username discoverHosts.${hostname}.users
      && homeConfigs ? ${key}
    then {default = homeConfigs.${key};}
    else {};
in {
  inherit mkNixos mkDarwin mkHome buildAllConfigs autoDefault;
}
