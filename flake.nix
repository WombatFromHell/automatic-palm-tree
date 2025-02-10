{
  description = "Unified NixOS and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    veridian.url = "github:WombatFromHell/veridian-controller";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils,
    home-manager,
    chaotic,
    veridian,
    ...
  }: let
    hostArgs = {
      methyl = {
        system = "x86_64-linux";
        username = "josh";
        myuid = 1000;
        hostname = "methyl";
      };
      laptop = {
        system = "x86_64-darwin";
        inherit (hostArgs.methyl) username;
        myuid = 501;
        hostname = "MacBookPro.lan";
      };
    };

    # Desktop modules
    mkDesktopSystem = extraModules:
      nixpkgs.lib.nixosSystem {
        inherit (hostArgs.methyl) system;
        specialArgs = {inherit hostArgs;};
        modules =
          [
            chaotic.nixosModules.default
            veridian.nixosModules.default
          ]
          ++ extraModules;
      };

    mkDesktopHome = username: hostname: let
      homePath = path: ./home/${hostname}/${path};
    in {
      home-manager = {
        extraSpecialArgs = {inherit hostArgs;};
        useGlobalPkgs = true;
        useUserPackages = true;
        users.${username}.imports = [
          (homePath "home.nix")
        ];
      };
    };
  in
    {
      nixosConfigurations = let
        deskHost = hostArgs.methyl.hostname;
        deskUser = hostArgs.${deskHost}.username;
        deskHostPath = path: ./nixos/${deskHost}/${path};
        deskHostHMPath = path: ./home/${deskHost}/${path};
        nixosModules = {
          system = [
            "hardware-configuration.nix"
            "configuration.nix"
            "modules/nvidia.nix"
            "modules/gigabyte-sleepfix.nix"
            "modules/mounts.nix"
            "modules/nvidia-pm"
          ];
          home = ["modules/openrgb/lightsout-system.nix"];
        };
      in {
        default = mkDesktopSystem [];
        # flatten our list of modules
        ${deskHost} = mkDesktopSystem (builtins.concatLists [
          (map deskHostPath nixosModules.system)
          # system-level support modules for home-manager
          (map deskHostHMPath nixosModules.home)
          [
            # home-manager config
            inputs.home-manager.nixosModules.home-manager
            (mkDesktopHome deskUser deskHost)
          ]
        ]);
      };
    }
    // flake-utils.lib.eachDefaultSystem (system: {
    });
}
