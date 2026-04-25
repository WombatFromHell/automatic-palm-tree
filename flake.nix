{
  description = "Unified Nix (Linux/Darwin) and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager-darwin = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
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

    hostname =
      if builtins.pathExists /etc/hostname
      then lib.trim (builtins.readFile /etc/hostname)
      else lib.trim (builtins.getEnv "HOST");
    username = lib.trim (builtins.getEnv "USER");
  in {
    nixosConfigurations = configs.nixos;
    darwinConfigurations = configs.darwin;
    homeConfigurations =
      configs.home
      // lib.optionalAttrs
      (hostname != "" && username != "" && configs.home ? "${username}@${hostname}")
      {default = configs.home."${username}@${hostname}";};
  };
}
