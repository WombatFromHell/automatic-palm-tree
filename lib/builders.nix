{
  lib,
  self,
  inputs,
  featuresLib,
}: let
  builderHelpers = import ./builder-helpers.nix {inherit lib self featuresLib;};

  availableFeatures =
    lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames featuresLib.discoveredFeatures));

  # Resolves feature paths for a platform
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

  # Single evalModules to extract unfree/overlays from features.
  # Only needed for HM-only hosts (overlays must be known before import nixpkgs).
  resolveHostContext = host: let
    hostFeatures = host.features or [];
    mergedCfg =
      (lib.evalModules {
        specialArgs = {
          inherit inputs;
          hostConfig = host;
        };
        modules =
          (resolveFeaturePaths hostFeatures "nixos"
            ++ resolveFeaturePaths hostFeatures "home")
          ++ [featuresLib.featureOptionsModule {_module.check = false;}];
      }).config;

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      (mergedCfg.unfreePackages or [])
    ]);

    homeOverlays = lib.unique (lib.flatten [
      (mergedCfg.overlays or [])
    ]);
  in {
    inherit allUnfree homeOverlays;
  };

  mkFeatureAggregator = host: platform: let
    hostFeatures = host.features or [];
    featurePaths = resolveFeaturePaths hostFeatures platform;
  in {
    imports = featurePaths ++ [featuresLib.featureOptionsModule];
  };

  # ── NixOS host builder ───────────────────────────────────────────────
  buildNixosConfigurations = discoveredHosts: let
    nixosHosts = lib.filterAttrs (_: h: h.isNixOS or false) discoveredHosts;
  in
    lib.mapAttrs (
      _name: host: let
        pkgsUnstable = import inputs.nixpkgs-unstable {
          inherit (host) system;
          config.allowUnfree = true;
        };
      in
        inputs.nixpkgs.lib.nixosSystem {
          modules = lib.flatten [
            (mkFeatureAggregator host "nixos")
            self.flakeModules.nix-settings
            self.flakeModules.nixos
            (builderHelpers.mkNixosUserModule host)
            (builderHelpers.resolveHostModules host "nixos")
            inputs.home-manager.nixosModules.home-manager
            ({
              config,
              lib,
              ...
            }: {
              # Collect unfree/overlays via nixos-level features (no pre-evaluation).
              # HM user overlays aren't read here to avoid a cycle (pkgs ↔ HM eval).
              nixpkgs.config.allowUnfree = true;
              nixpkgs.overlays = config.overlays;

              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit pkgsUnstable;
                  hostConfig = host;
                  inherit inputs self;
                };
                users =
                  lib.genAttrs host.hmUsernames (user:
                    builderHelpers.mkUserHomeModule {inherit user host;});
              };
            })
          ];
          specialArgs = {
            inherit pkgsUnstable;
            inherit inputs self;
            inherit (host) osUsernames hmUsernames bootstrap;
            hostConfig = host;
          };
        }
    )
    nixosHosts;

  # ── Home Manager–only host builder ───────────────────────────────────
  buildHomeConfigurations = discoveredHosts: let
    hmHosts = lib.filterAttrs (_: h: !(h.isNixOS or false)) discoveredHosts;
    mkHomeConfig = host: user: let
      ctx = resolveHostContext host;
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (host) system;
        config.allowUnfree = true;
      };
      pkgs = import inputs.nixpkgs {
        inherit (host) system;
        overlays = ctx.homeOverlays;
        config.allowUnfreePredicate = pkg:
          builtins.elem (lib.getName pkg) ctx.allUnfree;
      };
    in
      inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          (mkFeatureAggregator host "home")
          self.flakeModules.nix-settings
          (builderHelpers.mkUserHomeModule {inherit user host;})
          {targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);}
        ];
        extraSpecialArgs = {
          inherit pkgsUnstable;
          hostConfig = host;
          inherit inputs self;
        };
      };
  in
    builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList
      (_: hostEntry:
        map (user:
          lib.nameValuePair "${user}@${hostEntry.name}"
          (mkHomeConfig hostEntry user))
        hostEntry.hmUsernames)
      hmHosts));
in {
  inherit buildNixosConfigurations buildHomeConfigurations;
}
