{
  description = "Unified dendritic Nix/NixOS/Home-Manager configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-26.05-chilled/0.1";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs-unstable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    kait2en.url = "github:LukeChannings/KaiT2en-NixOS";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    xilo.url = "github:stubbedev/xilo?rev=4528483a1a261f5ed6578606d30526c6a908d1b4"; # v1.2.2

    dms = {
      url = "git+https://github.com/AvengeMedia/DankMaterialShell.git";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    dcal = {
      url = "git+https://github.com/AvengeMedia/dankcalendar.git";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {self, ...}: let
    cfg = import ./lib {
      inherit self inputs;
      lib = inputs.nixpkgs.lib;
    };
  in {
    inherit (cfg) nixosConfigurations homeConfigurations;
  };
}
