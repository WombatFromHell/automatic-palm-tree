# Feature machinery — discovery, path resolution, overlay resolution, options.
#
# The lowest layer of the loader: it only needs `lib`, `self` (to find
# features/), and `inputs` (to import feature files for overlay extraction).
# The config builders (lib/builders.nix) consume this.
{
  lib,
  self,
  inputs,
  ...
}: let
  # ── feature discovery ──
  featuresDir = self + /features;
  featuresDirExists = builtins.pathExists featuresDir;
  featureDirs = lib.optionalAttrs featuresDirExists (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir featuresDir)
  );

  discoveredFeatures = lib.mapAttrs (featureName: _: let
    dirPath = featuresDir + "/${featureName}";
    files = builtins.readDir dirPath;
    known = [
      "nixos"
      "home"
    ];
  in
    builtins.listToAttrs (lib.concatMap (
        p:
          lib.optional (builtins.hasAttr "${p}.nix" files && files."${p}.nix" == "regular") {
            name = p;
            value = dirPath + "/${p}.nix";
          }
      )
      known))
  featureDirs;

  featureOptionsModule = {
    lib,
    config,
    options,
    ...
  }: {
    options = {
      __overlays = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        internal = true;
        description = "Overlays to apply to pkgs (pure-extracted, no pre-eval).";
      };
      extraGroups = lib.mkOption {
        # attrset (feature -> [groups]) so multiple features merge by key, not last-wins
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = {};
        internal = true;
        description = "Groups to add isAdmin-enabled users to when this feature is enabled.";
      };
    };
    config.warnings = lib.optionals (config.extraGroups != {} && !(lib.hasAttrByPath ["users" "users"] options)) [
      "Feature module declares extraGroups ${builtins.toJSON config.extraGroups} but 'users.users' is unavailable in standalone home-manager modules."
    ];
  };

  # ── feature path resolution (direct path interpolation, idiomatic) ──
  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));

  # Resolves a host's feature list to file paths for one platform, reading the
  # single source of truth (discoveredFeatures) rather than re-walking features/.
  # A feature present without a module for this platform (hybrid) resolves to [].
  resolveFeaturePaths = featureList: platform:
    lib.flatten (
      map (f:
        if !builtins.hasAttr f discoveredFeatures
        then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
        else lib.optional (builtins.hasAttr platform discoveredFeatures.${f}) discoveredFeatures.${f}.${platform})
      featureList
    );

  # ── overlay resolution (pure, no evalModules) ──
  resolveHostOverlays = host: let
    paths = resolveFeaturePaths host.features "nixos" ++ resolveFeaturePaths host.features "home";
    extract = p: let
      evaluated = (import p) {
        inherit inputs lib;
        hostConfig = host;
        pkgs = null;
        pkgsUnstable = null;
        config = {};
      };
    in
      evaluated.__overlays or [];
  in
    lib.unique (lib.flatten (map extract paths));
in {
  inherit discoveredFeatures featureOptionsModule resolveFeaturePaths resolveHostOverlays;
}
