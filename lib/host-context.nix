# Pure functions for building the per-host context: feature resolution,
# unfree collection, package set construction, and user home module
# generation.
#
# pkgs.nix is imported internally — callers only need lib, self, and inputs.
{
  lib,
  self,
  inputs,
  ...
}: let
  pkgsLib = import ./pkgs.nix {inherit lib;};
  featuresLib = import ./features.nix {inherit lib self;};

  availableFeatures =
    lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames featuresLib.discoveredFeatures));

  # ── Host context mini-library ──────────────────────────────────────────
  #
  # The host context is the central seam between host declarations and
  # build outputs. It consolidates unfree collection (what used to be
  # three separate evalModules calls), feature resolution, and package
  # set construction into a single data structure consumed by the thin
  # builder wrappers.
  #
  # allUnfree is the union of unfree declarations from host-level,
  # all feature modules (batched across platforms), and per-user modules.
  #
  # mkHostContext returns { pkgsStable, pkgsUnstable, allUnfree,
  # nixosModules, homeModules, homeOverlays }.

  # Resolve feature module and overlay paths for a given platform in a single pass.
  # Unknown features throw a descriptive error; features without the requested
  # platform are silently skipped. Any "shared" module in a feature is included
  # alongside the platform-specific module. Overlay paths follow the same
  # eligibility rules as the original collectOverlayPathsForPlatform.
  resolveFeaturePaths = featureList: platform:
    let
      results = map (
        f:
          if !(featuresLib.discoveredFeatures ? ${f})
          then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
          else let
            feature = featuresLib.discoveredFeatures.${f};
            platformMod = feature.${platform} or null;
            sharedMod = feature.shared or null;
            hasPlatformOrShared = platformMod != null || sharedMod != null;
          in {
            modules = lib.filter (p: p != null) [platformMod sharedMod];
            overlayPath =
              if hasPlatformOrShared then feature.overlays or null
              else if feature ? overlays
                && !(feature ? nixos || feature ? home || feature ? shared)
              then feature.overlays
              else null;
          }
      ) featureList;
    in {
      modules = lib.flatten (map (r: r.modules) results);
      overlayPaths = lib.filter (p: p != null) (map (r: r.overlayPath) results);
    };

  # Collect unfree declarations from a list of module paths.
  # Returns [] when given no modules.
  collectUnfreeFromModules = modulePaths: host:
    if modulePaths == []
    then []
    else (pkgsLib.extractUnfree pkgsLib.mkUnfreeOptionsModule modulePaths {hostConfig = host;}).config.unfree;

  # Build a host context: unfree collection (batched across all feature modules
  # in a single evalModules call, plus a separate call for per-user modules),
  # overlay extraction (home-only — nixos overlays were dead code), and
  # package set construction.
  mkHostContext = host: let
    hostFeatures = host.features or [];

    nixosPaths = resolveFeaturePaths hostFeatures "nixos";
    homePaths = resolveFeaturePaths hostFeatures "home";

    userModulePaths = lib.concatLists (lib.attrValues (host.modules.perUser or {}));

    # Unfree is extracted from all feature modules in a single batch.
    # The platform doesn't matter — unfree declarations are just package names.
    allFeatureModules = nixosPaths.modules ++ homePaths.modules;
    featureUnfree = if allFeatureModules == [] then []
      else (pkgsLib.extractUnfree pkgsLib.mkUnfreeOptionsModule allFeatureModules {hostConfig = host;}).config.unfree;

    userUnfree = if userModulePaths == [] then []
      else (pkgsLib.extractUnfree pkgsLib.mkUnfreeOptionsModule userModulePaths {hostConfig = host;}).config.unfree;

    # Home overlays are extracted from home overlay paths and applied to
    # pkgsStable. NixOS overlays are intentionally skipped — the NixOS
    # builder creates its own nixpkgs instance via nixosSystem and the
    # collected overlays were never consumed.
    homeOverlays = if homePaths.overlayPaths == [] then []
      else lib.unique (pkgsLib.extractOverlays pkgsLib.mkOverlaysOptionsModule homePaths.overlayPaths inputs {hostConfig = host;});

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      featureUnfree
      userUnfree
    ]);

    # pkgsUnstable is intentionally built with [] overlays.
    # Overlays like nixgl.overlay are only needed for the stable
    # package set that Home Manager consumes.
    pkgsStable = pkgsLib.mkPkgs inputs.nixpkgs host.system allUnfree homeOverlays;
    pkgsUnstable = pkgsLib.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];
  in {
    inherit pkgsStable pkgsUnstable allUnfree homeOverlays;
    nixosModules = nixosPaths.modules;
    homeModules = homePaths.modules;
  };
in {
  inherit mkHostContext;
}
