{
  description = "Unified dendritic Nix/NixOS/Home-Manager configuration";

  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-26.05-chilled/0.1";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    dms = {
      url = "git+https://github.com/AvengeMedia/DankMaterialShell.git";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    dcal = {
      url = "git+https://github.com/AvengeMedia/dankcalendar.git";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    # quickshell = {
    #   url = "git+https://git.outfoxxed.me/quickshell/quickshell?rev=d99d87d5e5ec4e696815348692fdaaf0b6be1b2c";
    #   inputs.nixpkgs.follows = "nixpkgs-unstable";
    # };

    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    nixgl.url = "github:nix-community/nixGL";
    xilo.url = "github:stubbedev/xilo?rev=eef4d6d64a36cc5ec5390e997ebb677d16896fe6"; # v1.09
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [./modules];

      debug = false;
      systems = ["x86_64-linux"];

      perSystem = {pkgs, ...}: {
        devShells.default = pkgs.mkShell {
          # our './bootstrap.sh init' flow requires some dependencies
          packages = with pkgs; [
            git
            pkgconf
            cmake
          ];

          shellHook = ''
            export FUSE_USE_VERSION=31
          '';
        };
      };
    };
}
