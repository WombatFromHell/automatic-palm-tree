{
  lib,
  self,
  inputs,
}: let
  # ── host option schema (was lib/host-schema.nix) ──
  hostOptions = {
    options = {
      bootstrap = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Disable cache-dependent options during initial deployment.";
      };
      system = lib.mkOption {
        type = lib.types.str;
        description = "System architecture (e.g., x86_64-linux).";
      };
      isNixOS = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to build a NixOS configuration for this host.";
      };
      users = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            isAdmin = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            hmEnabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };
        });
        default = {};
        description = "Users defined for this host.";
      };
      isQemuVM = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this host is a QEMU/KVM virtual machine.";
      };
      features = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Features to enable for this host.";
      };
      nixosModules = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Host-local NixOS modules.";
      };
      homeModules = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.unspecified);
        default = {};
        description = "Per-user Home Manager modules, keyed by username.";
      };
    };
  };

  # ── feature discovery (was lib/features.nix) ──
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
          lib.optional (files ? "${p}.nix" && files."${p}.nix" == "regular") {
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
      overlays = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        internal = true;
        description = "Overlays to apply to pkgs when this feature is enabled.";
      };
      unstableOverlays = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        internal = true;
        description = "Overlays to apply to pkgsUnstable when this feature is enabled.";
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        internal = true;
        description = "Groups to add isAdmin-enabled users to when this feature is enabled.";
      };
    };
    config.warnings = lib.optionals (config.extraGroups != [] && !(options ? users.users)) [
      "Feature module declares extraGroups ${builtins.toJSON config.extraGroups} but 'users.users' is unavailable in standalone home-manager modules."
    ];
  };

  # ── feature path resolution ──
  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));

  resolveFeaturePaths = featureList: platform:
    lib.flatten (
      map (f:
        if !(discoveredFeatures ? ${f})
        then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
        else let
          feature = discoveredFeatures.${f};
          platformMod = feature.${platform} or null;
        in
          lib.filter (p: p != null) [platformMod])
      featureList
    );

  # ── overlay resolution ──
  # Note: separate evalModules pass to extract overlays before pkgs exists.
  # Needed because overlays must be baked into the pkgs import, but feature
  # modules are loaded during the main eval. The ceiling is eval time for
  # host configs with many features; if it ever matters, cache results.
  resolveHostOverlays = host: let
    hostFeatures = host.features or [];
    mergedCfg =
      (lib.evalModules {
        specialArgs = {
          inherit inputs;
          hostConfig = host;
        };
        modules =
          resolveFeaturePaths hostFeatures "nixos"
          ++ resolveFeaturePaths hostFeatures "home"
          ++ [featureOptionsModule {_module.check = false;}];
      }).config;
  in {
    stable = lib.unique (lib.flatten (mergedCfg.overlays or []));
    unstable = lib.unique (lib.flatten (mergedCfg.unstableOverlays or []));
  };

  # ── Home Manager user module (was lib/builder-helpers.nix) ──
  mkUserHomeModule = {
    user,
    host,
  }: let
    homeFeaturePaths = resolveFeaturePaths (host.features or []) "home";
  in {
    imports = lib.flatten [
      homeFeaturePaths
      (host.homeModules.${user} or [])
      featureOptionsModule
      (self + /modules/defaults/home-manager.nix)
    ];
    _module.args.user = user;
  };

  # ── helper: emit a warning for admin users on non-NixOS hosts ──
  checkAdminWarning = name: cfg:
    lib.optional (!cfg.isNixOS) (
      let
        adminNames = lib.filter (n: cfg.users.${n}.isAdmin) (builtins.attrNames cfg.users);
      in
        lib.optional (adminNames != [])
        "${name}: 'isNixOS = false', but users.${lib.concatStringsSep ", " adminNames}.isAdmin = true! "
        + "This is a no-op on standalone home-manager hosts."
    );

  # ── NixOS configuration builder ──
  # hostsWithPkgs must have pre-computed .pkgsUnstable (with feature overlays).
  buildNixosConfigurations = hostsWithPkgs: let
    nixosHosts = lib.filterAttrs (_: h: h.isNixOS or false) hostsWithPkgs;
  in
    lib.mapAttrs (
      _name: host:
        inputs.nixpkgs.lib.nixosSystem {
          modules = lib.flatten [
            # Feature modules for the NixOS platform
            {
              imports =
                resolveFeaturePaths (host.features or []) "nixos"
                ++ [featureOptionsModule];
            }
            # Nix daemon settings
            (self + /modules/nix-settings.nix)
            # Common NixOS defaults
            (self + /modules/defaults/nixos.nix)
            # NixOS user defaults
            (self + /modules/defaults/nixos-users.nix)
            # Host-local modules
            (host.nixosModules or [])
            # Home Manager integration
            inputs.home-manager.nixosModules.home-manager
            # Inline: unfree pkgs, overlay wiring, pkgsUnstable, HM wiring
            ({
              config,
              lib,
              ...
            }: {
              nixpkgs.config.allowUnfree = true;
              nixpkgs.overlays = config.overlays;

              _module.args.pkgsUnstable = host.pkgsUnstable;

              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit (host) pkgsUnstable;
                  hostConfig = host;
                  inherit inputs self;
                };
                users =
                  lib.genAttrs host.hmUsernames (user:
                    mkUserHomeModule {inherit user host;});
              };
            })
          ];
          specialArgs = {
            inherit (host) osUsernames hmUsernames bootstrap;
            inherit inputs self;
            hostConfig = host;
          };
        }
    )
    nixosHosts;

  # ── Home Manager configuration builder ──
  # hostsWithPkgs must have pre-computed .pkgs (with stable overlays) and
  # .pkgsUnstable (with unstable overlays).
  buildHomeConfigurations = hostsWithPkgs: let
    hmHosts = lib.filterAttrs (_: h: !(h.isNixOS or false)) hostsWithPkgs;

    mkHomeConfigsForHost = host: let
      mkHomeConfig = user:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit (host) pkgs;
          modules = [
            (self + /modules/nix-settings.nix)
            (mkUserHomeModule {inherit user host;})
            {targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);}
          ];
          extraSpecialArgs = {
            inherit (host) pkgsUnstable;
            hostConfig = host;
            inherit inputs self;
          };
        };
    in
      map (user: lib.nameValuePair "${user}@${host.name}" (mkHomeConfig user)) host.hmUsernames;
  in
    builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: mkHomeConfigsForHost) hmHosts));
in {
  inherit
    hostOptions
    discoveredFeatures
    featureOptionsModule
    resolveHostOverlays
    buildNixosConfigurations
    buildHomeConfigurations
    checkAdminWarning
    ;
}
