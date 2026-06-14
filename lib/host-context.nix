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
  # The allUnfree list is the union of unfree declarations from:
  #   host-level (host.unfree), NixOS features, Home features, and
  #   per-user modules — extracted in a single pass.
  #
  # mkHostContext returns { pkgsStable, pkgsUnstable, allUnfree,
  # nixosModules, homeModules, nixosOverlays, homeOverlays }.

  # Resolve feature module paths for a given platform.
  # Unknown features throw a descriptive error; features without the
  # requested platform module are silently skipped.
  # When resolving for "nixos" or "home", any "shared" module present
  # in the same feature is automatically included.
  resolvePlatformModules = featureList: attrPath:
    assert builtins.elem attrPath ["nixos" "home" "shared"];
      lib.filter (p: p != null) (
        lib.flatten (map (
            f:
              if !(featuresLib.discoveredFeatures ? ${f})
              then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
              else let
                platformMod = featuresLib.discoveredFeatures.${f}.${attrPath} or null;
              in
                if attrPath == "shared"
                then [platformMod]
                else [
                  platformMod
                  (featuresLib.discoveredFeatures.${f}.shared or null)
                ]
          )
          featureList)
      );

  # Collect overlay.nix paths for features that contribute to the given platform.
  # A feature's overlays apply to a platform if:
  #   1. The feature has a module for that platform (nixos, home, or shared), OR
  #   2. The feature ONLY has overlays.nix (no nixos, home, or shared modules) —
  #      in that case its overlays apply to every platform.
  collectOverlayPathsForPlatform = featureList: platform:
    lib.filter (p: p != null) (
      map (
        f:
          if !(featuresLib.discoveredFeatures ? ${f})
          then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
          else if
            featuresLib.discoveredFeatures.${f} ? ${platform}
            || featuresLib.discoveredFeatures.${f} ? shared
          then
            # Has a platform/shared module — include its overlays.
            featuresLib.discoveredFeatures.${f}.overlays or null
          else if
            featuresLib.discoveredFeatures.${f} ? overlays
            && !(featuresLib.discoveredFeatures.${f} ? nixos
              || featuresLib.discoveredFeatures.${f} ? home
              || featuresLib.discoveredFeatures.${f} ? shared)
          then
            # Overlay-only feature — its overlays apply to all platforms.
            featuresLib.discoveredFeatures.${f}.overlays
          else null
      )
      featureList
    );

  # Collect overlay declarations from a list of module paths.
  collectOverlaysFromModules = modulePaths: host:
    if modulePaths == []
    then []
    else pkgsLib.extractOverlays pkgsLib.mkOverlaysOptionsModule modulePaths inputs {hostConfig = host;};

  # Collect unfree declarations from a list of module paths.
  # Returns [] when given no modules.
  collectUnfreeFromModules = modulePaths: host:
    if modulePaths == []
    then []
    else (pkgsLib.extractUnfree pkgsLib.mkUnfreeOptionsModule modulePaths {hostConfig = host;}).config.unfree;

  # Build a host context: a single data structure that encapsulates
  # unfree collection, package set construction, and module resolution.
  #
  # This consolidates what used to be three separate evalModules calls
  # (two from resolveFeatures + one from collectUnfree) into one.
  # The union of all unfree declarations from host-level, feature-level,
  # and per-user modules is extracted in a single pass.
  mkHostContext = host: let
    resolveFeatures = platform: let
      modules = resolvePlatformModules (host.features or []) platform;
      overlayPaths = collectOverlayPathsForPlatform (host.features or []) platform;
    in
      if modules == [] && overlayPaths == []
      then {
        modules = [];
        unfree = [];
        overlays = [];
      }
      else {
        inherit modules;
        unfree = collectUnfreeFromModules modules host;
        # Overlays are extracted from dedicated overlays.nix files rather
        # than from the feature modules themselves. This keeps featureOverlays
        # out of the builder eval entirely.
        overlays = collectOverlaysFromModules overlayPaths host;
      };

    nixosFeaturesData = resolveFeatures "nixos";
    homeFeaturesData = resolveFeatures "home";

    userModulePaths = lib.concatLists (lib.attrValues (host.modules.perUser or {}));

    # Overlays are extracted from overlays.nix files (not the feature modules
    # themselves), so feature modules don't need mkOverlaysOptionsModule at
    # eval time. The overlay extraction runs as a dry-run eval during discovery.
    nixosOverlays = lib.unique nixosFeaturesData.overlays;
    homeOverlays = lib.unique homeFeaturesData.overlays;

    # allUnfree is the union of host-level declarations and unfree
    # packages extracted from all feature and per-user modules.
    allUnfree = lib.unique (
      lib.flatten [
        (host.unfree or [])
        (collectUnfreeFromModules
          (nixosFeaturesData.modules ++ homeFeaturesData.modules ++ userModulePaths)
          host)
      ]
    );

    # pkgsUnstable is intentionally built with [] overlays.
    # Overlays like nixgl.overlay are only needed for the stable
    # package set that Home Manager consumes. If unstable-only
    # overlays are ever needed, introduce an unstableOverlays
    # collection path.
    pkgsStable = pkgsLib.mkPkgs inputs.nixpkgs host.system allUnfree homeOverlays;
    pkgsUnstable = pkgsLib.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];
  in {
    inherit pkgsStable pkgsUnstable allUnfree nixosOverlays homeOverlays;
    nixosModules = nixosFeaturesData.modules;
    homeModules = homeFeaturesData.modules;
  };
in {
  inherit mkHostContext;
}
