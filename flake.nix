{
  description = "Unified dendritic Nix/NixOS/Home-Manager configuration";

  inputs = {
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
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    nixgl.url = "github:nix-community/nixGL";
    xilo.url = "github:stubbedev/xilo?rev=ada25182245e2f80e2490f6620a8292db136cb9c"; # v1.13
  };

  outputs = inputs @ {self, ...}: let
    cfg = import ./modules {
      inherit self inputs;
      lib = inputs.nixpkgs.lib;
    };
  in {
    inherit (cfg) nixosConfigurations homeConfigurations features hostPackageSets;

    devShells.x86_64-linux.default = let
      pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    in
      pkgs.mkShell {
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
}
