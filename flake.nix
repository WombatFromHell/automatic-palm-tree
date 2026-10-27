{
  description = "Unified dendritic Nix/NixOS/Home-Manager configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-26.05-chilled/0.1";
    nixpkgs-unstable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    #
    kait2en.url = "github:LukeChannings/KaiT2en-NixOS";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    xilo.url = "github:stubbedev/xilo?rev=4528483a1a261f5ed6578606d30526c6a908d1b4"; # v1.2.2
    #
    beryl-utils.url = "github:WombatFromHell/beryl-utils";
    beryl-gamemode.url = "github:WombatFromHell/beryl-gamemode";
    niri-spicy.url = "github:WombatFromHell/niri-spicy-builder";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    #
    dms = {
      url = "github:duxlabs-dev/dux-shell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    dcal = {
      url = "github:duxlabs-dev/dux-calendar";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs = inputs @ {self, ...}: let
    inherit (inputs.nixpkgs) lib;
    cfg = import ./lib {
      inherit self inputs lib;
    };

    # The systems we check come from the configurations themselves, so a host that targets a
    # system outside this list cannot hide behind a missing check.
    supportedSystems = lib.unique (lib.mapAttrsToList
      (_: config: config.pkgs.stdenv.hostPlatform.system)
      (cfg.nixosConfigurations // cfg.homeConfigurations));

    # One check per configuration: the derivation `nix flake check` would build for it.
    mkChecks = system: kind: build:
      lib.mapAttrs'
      (name: config: lib.nameValuePair "${kind}-${name}" (build config))
      (lib.filterAttrs
        (_: config: config.pkgs.stdenv.hostPlatform.system == system)
        cfg."${kind}Configurations");

  in {
    inherit (cfg) nixosConfigurations homeConfigurations;

    # Expose checks so nix-fast-build (and nix flake check) can evaluate them
    checks = lib.genAttrs supportedSystems (
      system:
        (mkChecks system "nixos" (config: config.config.system.build.toplevel))
        // (mkChecks system "home" (config: config.activationPackage))
    );
  };
}
