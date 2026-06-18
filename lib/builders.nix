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

  resolveHostOverlays = host: let
    hostFeatures = host.features or [];
    mergedCfg =
      (lib.evalModules {
        specialArgs = {
          inherit inputs;
          hostConfig = host;
        };
        modules =
          # Evaluate BOTH "nixos" and "home" paths. This ensures that NixOS hosts
          # pick up overlays declared in shared or nixos feature modules, preventing
          # a mismatch between the standalone HM package set and the NixOS HM package set.
          resolveFeaturePaths hostFeatures "nixos"
          ++ resolveFeaturePaths hostFeatures "home"
          ++ [featuresLib.featureOptionsModule {_module.check = false;}];
      }).config;
  in {
    stable = lib.unique (lib.flatten [(mergedCfg.overlays or [])]);
    unstable = lib.unique (lib.flatten [(mergedCfg.unstableOverlays or [])]);
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
      _name: host:
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
              nixpkgs.config.allowUnfree = true;
              nixpkgs.overlays = config.overlays;

              _module.args.pkgsUnstable = import inputs.nixpkgs-unstable {
                inherit (host) system;
                overlays = (resolveHostOverlays host).unstable;
                config.allowUnfree = true;
              };

              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  pkgsUnstable = import inputs.nixpkgs-unstable {
                    inherit (host) system;
                    overlays = (resolveHostOverlays host).unstable;
                    config.allowUnfree = true;
                  };
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
            # Remove pkgsUnstable from here to avoid conflicts!
            inherit (host) osUsernames hmUsernames bootstrap;
            inherit inputs self;
            hostConfig = host;
          };
        }
    )
    nixosHosts;

  buildHomeConfigurations = discoveredHosts: let
    hmHosts = lib.filterAttrs (_: h: !(h.isNixOS or false)) discoveredHosts;

    mkHomeConfigsForHost = host: let
      hostOverlays = resolveHostOverlays host;
      pkgs = import inputs.nixpkgs {
        inherit (host) system;
        overlays = hostOverlays.stable;
        config.allowUnfree = true;
      };
      # Create the unified pkgsUnstable with feature overlays applied
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (host) system;
        overlays = hostOverlays.unstable;
        config.allowUnfree = true;
      };
      mkHomeConfig = user:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
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
      map (user: lib.nameValuePair "${user}@${host.name}" (mkHomeConfig user)) host.hmUsernames;
  in
    builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: mkHomeConfigsForHost) hmHosts));
in {
  inherit buildNixosConfigurations buildHomeConfigurations;
}
