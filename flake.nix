{
  description = "Unified dendritic Nix/NixOS/Home-Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nix-cachyos-kernel,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [./modules];

      systems = ["x86_64-linux"];
    };
}
