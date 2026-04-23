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
    haumea = {
      url = "github:nix-community/haumea/v0.2.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    ...
  }: let
    inherit (nixpkgs) lib;
    hostsDir = ./modules/hosts;

    core = import ./modules/core {inherit lib inputs self hostsDir;};
    configs = core.buildConfigs core.discoverHosts;
  in {
    nixosConfigurations = configs.nixos;
    darwinConfigurations = configs.darwin;
    homeConfigurations = configs.home;
  };
}
