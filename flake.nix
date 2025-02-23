{
  description = "Unified Nix (Linux/Darwin) and Home Manager configuration";

  inputs = {
    # nixos inputs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    veridian.url = "github:WombatFromHell/veridian-controller?rev=489fca55e84ca3f647227686cf1ff5da52196979"; # pin to v0.2.9

    # darwin inputs
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager-darwin = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };

    # shared inputs
    flake-parts.url = "github:hercules-ci/flake-parts";
    neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    home-manager,
    plasma-manager,
    chaotic,
    nix-darwin,
    neovim-nightly-overlay,
    veridian,
    ...
  }: let
    inherit (nixpkgs) lib;

    hosts = import ./lib/hosts.nix;
    # Filter only enabled hosts
    enabledHosts = lib.filterAttrs (_: v: v.enable or false) hosts;
    # Generate a unique list of systems from enabled hosts
    systems = lib.lists.unique (builtins.attrValues (builtins.mapAttrs (_: v: v.system) enabledHosts));

    # shortcut to check if a host is on Darwin based on hosts.nix
    isDarwin = hostArgs: builtins.elem hostArgs.system ["x86_64-darwin" "aarch64-darwin"];

    mkHome = import ./lib/home.nix {inherit lib inputs isDarwin;};
    mkSystem = import ./lib/system.nix {inherit lib inputs isDarwin mkHome;};
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      inherit systems;

      flake = {
        # Auto-generate system configurations for enabled hosts
        nixosConfigurations =
          builtins.mapAttrs (
            name: hostArgs:
              if hostArgs.system == "x86_64-linux"
              then mkSystem hostArgs
              else null
          )
          enabledHosts;

        darwinConfigurations =
          builtins.mapAttrs (
            name: hostArgs:
              if hostArgs.system == "x86_64-darwin"
              then mkSystem hostArgs
              else null
          )
          enabledHosts;
      };
    };
}
