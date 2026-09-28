{
  self,
  lib,
  inputs,
  ...
}: let
  flakeLib = import ../lib {inherit lib self inputs;};

  # ── resolve overlays and pre-compute overlay-resolved pkgs for each host ──
  # This runs once here so that hostPackageSets and the configs use the
  # same pkgs/pkgsUnstable with the same overlays applied.
  hostsWithPkgs = lib.mapAttrs (_name: host: let
    hostOverlays = flakeLib.resolveHostOverlays host;
  in
    host
    // {
      pkgs = import inputs.nixpkgs {
        inherit (host) system;
        overlays = hostOverlays;
        config.allowUnfree = true;
      };
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (host) system;
        config.allowUnfree = true;
      };
    })
  flakeLib.discoveredHosts;
in {
  features = flakeLib.discoveredFeatures;

  nixosConfigurations = flakeLib.buildNixosConfigurations hostsWithPkgs;
  homeConfigurations = flakeLib.buildHomeConfigurations hostsWithPkgs;

  hostPackageSets =
    lib.mapAttrs (_: h: {
      inherit (h) pkgs pkgsUnstable;
    })
    hostsWithPkgs;
}
