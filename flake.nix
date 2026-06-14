{
  description = "Unified dendritic Nix/NixOS/Home-Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms = {
      url = "git+https://github.com/AvengeMedia/DankMaterialShell.git";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    # quickshell = {
    #   url = "git+https://git.outfoxxed.me/quickshell/quickshell?rev=d99d87d5e5ec4e696815348692fdaaf0b6be1b2c";
    #   inputs.nixpkgs.follows = "nixpkgs-unstable";
    # };

    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
    nixgl.url = "github:nix-community/nixGL";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [./modules];

      systems = ["x86_64-linux"];
    };
}
