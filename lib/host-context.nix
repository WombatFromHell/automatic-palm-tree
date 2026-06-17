{
  lib,
  self,
  inputs,
  ...
}: let
  builderHelpers = import ./builder-helpers.nix {inherit lib self;};
  featuresLib = import ./features.nix {inherit lib self;};

  availableFeatures =
    lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames featuresLib.discoveredFeatures));

  resolveFeaturePaths = featureList: platform: let
    results =
      map (
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
              if hasPlatformOrShared
              then feature.overlays or null
              else if
                feature ? overlays
                && !(feature ? nixos || feature ? home || feature ? shared)
              then feature.overlays
              else null;
          }
      )
      featureList;
  in {
    modules = lib.flatten (map (r: r.modules) results);
    overlayPaths = lib.filter (p: p != null) (map (r: r.overlayPath) results);
  };

  # Temporary inline extractors — will be fully removed in Step 3
  # when features migrate to inline declarations via feature-options.nix
  extractUnfree = modulePaths: extraSpecialArgs:
    if modulePaths == []
    then []
    else
      (lib.evalModules {
        modules =
          modulePaths
          ++ [
            builderHelpers.mkUnfreeOptionsModule
            {_module.check = false;}
            {
              imports = [
                {
                  _module.args.pkgs = throw "pkgs accessed during unfree extraction";
                  _module.args.pkgsUnstable = throw "pkgsUnstable accessed during unfree extraction";
                }
              ];
            }
          ];
        specialArgs =
          {
            inherit lib inputs;
            config = {};
            options = {};
            self = {};
            hostConfig = {};
          }
          // extraSpecialArgs;
      }).config.unfree;

  extractOverlays = modulePaths: extraSpecialArgs:
    if modulePaths == []
    then []
    else
      (lib.evalModules {
        modules =
          modulePaths
          ++ [
            {
              options.featureOverlays = lib.mkOption {
                type = lib.types.listOf lib.types.unspecified;
                default = [];
                internal = true;
              };
            }
            {_module.check = false;}
            {config = lib.mkForce {};}
            {
              imports = [
                {
                  _module.args.pkgs = throw "pkgs accessed during overlay extraction";
                  _module.args.pkgsUnstable = throw "pkgsUnstable accessed during overlay extraction";
                }
              ];
            }
          ];
        specialArgs =
          {
            inherit lib inputs;
            config = {};
            options = {};
            self = {};
            hostConfig = {};
          }
          // extraSpecialArgs;
      }).config.featureOverlays;

  mkHostContext = host: let
    hostFeatures = host.features or [];
    nixosPaths = resolveFeaturePaths hostFeatures "nixos";
    homePaths = resolveFeaturePaths hostFeatures "home";
    userModulePaths = lib.concatLists (lib.attrValues (host.modules.perUser or {}));

    allFeatureModules = nixosPaths.modules ++ homePaths.modules;
    featureUnfree = extractUnfree allFeatureModules {hostConfig = host;};
    userUnfree = extractUnfree userModulePaths {hostConfig = host;};

    homeOverlays =
      if homePaths.overlayPaths == []
      then []
      else lib.unique (extractOverlays homePaths.overlayPaths {hostConfig = host;});

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      featureUnfree
      userUnfree
    ]);

    pkgsStable = builderHelpers.mkPkgs inputs.nixpkgs host.system allUnfree homeOverlays;
    pkgsUnstable = builderHelpers.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];
  in {
    inherit pkgsStable pkgsUnstable allUnfree homeOverlays;
    nixosModules = nixosPaths.modules;
    homeModules = homePaths.modules;
  };
in {
  inherit mkHostContext;
}
