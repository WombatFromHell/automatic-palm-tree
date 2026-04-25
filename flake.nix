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

    lix = {
      url = "https://git.lix.systems/lix-project/lix/archive/main.tar.gz";
      flake = false;
    };
    lix-module = {
      url = "https://git.lix.systems/lix-project/nixos-module/archive/main.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.lix.follows = "lix";
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
