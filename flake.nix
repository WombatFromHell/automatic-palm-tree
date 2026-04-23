{
  description = "Unified Nix (Linux/Darwin) and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    ...
  }: let
    inherit (nixpkgs) lib;
    hostsDir = ./modules/hosts;
    supportedSystems = ["x86_64-linux" "aarch64-darwin" "aarch64-linux"];

    core = import ./modules/core {inherit lib inputs self hostsDir;};

    allConfigs = core.buildAllConfigs core.discoverHosts supportedSystems;
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = supportedSystems;

      perSystem = {pkgs, ...}: {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [nixpkgs-fmt alejandra];
        };
      };

      flake = {
        nixosConfigurations = allConfigs.nixos;
        darwinConfigurations = allConfigs.darwin;
        homeConfigurations =
          allConfigs.home
          // core.autoDefault allConfigs.home core.discoverHosts;
      };
    };
}
