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
    results = map (f:
      if !(featuresLib.discoveredFeatures ? ${f})
      then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
      else let
        feature = featuresLib.discoveredFeatures.${f};
        platformMod = feature.${platform} or null;
        sharedMod = feature.shared or null;
      in
        lib.filter (p: p != null) [platformMod sharedMod])
    featureList;
  in
    lib.flatten results;

  mkHostContext = host: let
    hostFeatures = host.features or [];

    nixosModules = resolveFeaturePaths hostFeatures "nixos";
    homeModules = resolveFeaturePaths hostFeatures "home";
    userModulePaths = lib.concatLists (lib.attrValues (host.modules.perUser or {}));

    mergedConfig =
      (lib.evalModules {
        specialArgs = {
          inherit inputs;
          hostConfig = host;
        }; # <--- ADD THIS
        modules =
          nixosModules
          ++ homeModules
          ++ userModulePaths
          ++ [
            featuresLib.featureOptionsModule
            {_module.check = false;}
          ];
      }).config;

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      (mergedConfig.unfreePackages or [])
    ]);

    homeOverlays = mergedConfig.overlays or [];

    pkgsStable = builderHelpers.mkPkgs inputs.nixpkgs host.system allUnfree homeOverlays;
    pkgsUnstable = builderHelpers.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];
  in {
    inherit pkgsStable pkgsUnstable allUnfree homeOverlays;
    inherit nixosModules homeModules;
  };
in {
  inherit mkHostContext;
}
