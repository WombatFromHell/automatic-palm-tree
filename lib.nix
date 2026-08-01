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
    config.warnings = lib.optionals (config.extraGroups != [] && !(builtins.hasAttr "users.users" options)) [
      "Feature module declares extraGroups ${builtins.toJSON config.extraGroups} but 'users.users' is unavailable in standalone home-manager modules."
    ];
  };

  # ── feature path resolution ──
  availableFeatures = lib.concatStringsSep ", " (lib.naturalSort (lib.attrNames discoveredFeatures));

  resolveFeaturePaths = featureList: platform:
    lib.flatten (
      map (f:
        if !(builtins.hasAttr f discoveredFeatures)
        then throw "Unknown feature '${f}'. Available: ${availableFeatures}"
        else let
          feature = builtins.getAttr f discoveredFeatures;
          platformMod =
            if builtins.hasAttr platform feature
            then builtins.getAttr platform feature
            else null;
        in
          lib.filter (p: p != null) [platformMod])
      featureList
    );

  # ── overlay resolution ──
  resolveHostOverlays = host: let
    hostFeatures =
      if builtins.hasAttr "features" host
      then host.features
      else [];
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
    stableOverlays =
      if builtins.hasAttr "overlays" mergedCfg
      then mergedCfg.overlays
      else [];
    unstableOverlays =
      if builtins.hasAttr "unstableOverlays" mergedCfg
      then mergedCfg.unstableOverlays
      else [];
  in {
    stable = lib.unique (lib.flatten stableOverlays);
    unstable = lib.unique (lib.flatten unstableOverlays);
  };

  # ── Home Manager user module (was lib/builder-helpers.nix) ──
  mkUserHomeModule = {
    user,
    host,
  }: let
    hostFeatures =
      if builtins.hasAttr "features" host
      then host.features
      else [];
    homeFeaturePaths = resolveFeaturePaths hostFeatures "home";
    userHomeModules =
      if builtins.hasAttr user host.homeModules
      then host.homeModules.${user}
      else [];
  in {
    imports = lib.flatten [
      homeFeaturePaths
      userHomeModules
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
  buildNixosConfigurations = hostsWithPkgs: let
    nixosHosts = lib.filterAttrs (_: h: builtins.hasAttr "isNixOS" h && h.isNixOS) hostsWithPkgs;
  in
    lib.mapAttrs (
      _name: host:
        inputs.nixpkgs.lib.nixosSystem {
          modules = lib.flatten [
            # Feature modules for the NixOS platform
            {
              imports =
                resolveFeaturePaths (
                  if builtins.hasAttr "features" host
                  then host.features
                  else []
                ) "nixos"
                ++ [featureOptionsModule];
            }
            # Nix daemon settings
            (self + /modules/nix-settings.nix)
            # Common NixOS defaults
            (self + /modules/defaults/nixos.nix)
            # NixOS user defaults
            (self + /modules/defaults/nixos-users.nix)
            # Host-local modules
            (
              if builtins.hasAttr "nixosModules" host
              then host.nixosModules
              else []
            )
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
  buildHomeConfigurations = hostsWithPkgs: let
    hmHosts = lib.filterAttrs (_: h: !(builtins.hasAttr "isNixOS" h && h.isNixOS)) hostsWithPkgs;

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
