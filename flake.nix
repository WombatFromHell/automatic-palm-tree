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
    system = "x86_64-linux";
    sharedArgs = {
      username = "josh";
      myuid = 1000;
      desktopHost = "methyl";
    };

    # Common Desktop modules
    mkSystem = extraModules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {inherit sharedArgs;};
        modules =
          [
            chaotic.nixosModules.default
            veridian.nixosModules.default
          ]
          ++ extraModules;
      };

    # Home-manager configuration
    mkHomeConfig = {
      extraSpecialArgs = {inherit sharedArgs;};
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${sharedArgs.username} = import ./home/home.nix;
    };

    # Desktop specific modules
    methylModules = [
      ./nixos/methyl/hardware-configuration.nix
      ./nixos/methyl/configuration.nix
      ./nixos/methyl/modules/nvidia.nix
      ./nixos/methyl/modules/gigabyte-sleepfix.nix
      ./home/modules/openrgb/lightsout-system.nix
      ./nixos/methyl/modules/mounts.nix
      ./nixos/methyl/modules/nvidia-pm

      inputs.home-manager.nixosModules.home-manager
      {home-manager = mkHomeConfig;}
    ];
  in
    {
      nixosConfigurations = {
        default = mkSystem [];
        methyl = mkSystem methylModules;
      };
    }
    // flake-utils.lib.eachDefaultSystem (system: {
    });
}
