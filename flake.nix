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

    # Upstream watch/gamemode tools (raw/…/flake.nix URLs are not fetchable as
    # flake inputs — Nix needs a tarball, so use the github ref).
    beryl-utils = {
      url = "github:WombatFromHell/beryl-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    beryl-gamemode = {
      url = "github:WombatFromHell/beryl-gamemode";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
    inherit (inputs.nixpkgs) lib;
    cfg = import ./lib {
      inherit self inputs lib;
    };

    supportedSystems = ["x86_64-linux"];

    # Helper to map NixOS configurations to checks for a given system
    nixosChecksFor = system:
      lib.mapAttrs'
      (name: config: lib.nameValuePair "nixos-${name}" config.config.system.build.toplevel)
      (lib.filterAttrs (name: config: config.pkgs.system == system) cfg.nixosConfigurations);

    # Helper to map Home Manager configurations to checks for a given system
    homeChecksFor = system:
      lib.mapAttrs'
      (name: config: lib.nameValuePair "home-${name}" config.activationPackage)
      (lib.filterAttrs (name: config: config.pkgs.system == system) cfg.homeConfigurations);
  in {
    inherit (cfg) nixosConfigurations homeConfigurations;

    # Expose checks so nix-fast-build (and nix flake check) can evaluate them
    checks = lib.genAttrs supportedSystems (
      system:
        (nixosChecksFor system) // (homeChecksFor system)
    );
  };
}
