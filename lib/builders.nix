{
  lib,
  self,
  inputs,
}: let
  builderHelpers = import ./builder-helpers.nix {inherit lib self;};
  featuresLib = import ./features.nix {inherit lib self;};

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

  # Evaluates NixOS and HM features in ISOLATED sandboxes to extract
  # unfree/overlays without causing option declaration collisions.
  resolveHostContext = host: let
    hostFeatures = host.features or [];
    nixosModules = resolveFeaturePaths hostFeatures "nixos";
    homeModules = resolveFeaturePaths hostFeatures "home";

    evalOpts = mods:
      (lib.evalModules {
        specialArgs = {
          inherit inputs;
          hostConfig = host;
        };
        modules = mods ++ [featuresLib.featureOptionsModule {_module.check = false;}];
      }).config;

    nixosCfg = evalOpts nixosModules;
    homeCfg = evalOpts homeModules;

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      (nixosCfg.unfreePackages or [])
      (homeCfg.unfreePackages or [])
    ]);

    homeOverlays = lib.unique (lib.flatten [
      (nixosCfg.overlays or [])
      (homeCfg.overlays or [])
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
        ctx = resolveHostContext host;
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
            {
              # Apply extracted unfree/overlays natively
              nixpkgs.config.allowUnfreePredicate = pkg:
                builtins.elem (lib.getName pkg) ctx.allUnfree;
              nixpkgs.overlays = ctx.homeOverlays;

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
            }
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
