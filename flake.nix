{
  description = "Unified dendritic Nix/NixOS/Home-Manager configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-26.05-chilled/0.1";
    nixpkgs-unstable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    #
    # Six more inputs bring their own nixpkgs, so the lock carries seven trees in total
    # (ours x2, beryl-utils, kait2en, niri-spicy, nix-cachyos-kernel, xilo). None of them
    # uses `follows`, and that is the boundary: forcing one to follow ours would evaluate it
    # against a rev its CI never built, so every path it publishes from its own cache stops
    # matching — the CachyOS kernel and KaiT2en's kernel/firmware would rebuild locally, on
    # the host with the least RAM. The caches named in modules/cache-registry.nix are the
    # same story: each is somebody else's build of their own rev, so nothing here may repin
    # them.
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

    # Systems come from the host records, not from forcing each configuration: naming the checks
    # cost ~500MB of eval RAM walking config.pkgs for every host. Same value as before, since
    # `pkgsFor` is built from host.system, so a host outside this list still cannot hide behind a
    # missing check.
    supportedSystems = lib.unique (map (h: h.system) (lib.attrValues cfg.hostsWithPkgs));

    # A home configuration is keyed "<user>@<host>", so read the host back out of the name.
    hostOf = kind: name:
      if kind == "home"
      then lib.last (lib.splitString "@" name)
      else name;

    # One check per configuration: the derivation `nix flake check` would build for it.
    mkChecks = system: kind: build:
      lib.mapAttrs'
      (name: config: lib.nameValuePair "${kind}-${name}" (build config))
      (lib.filterAttrs
        (name: _config: cfg.hostsWithPkgs.${hostOf kind name}.system == system)
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
