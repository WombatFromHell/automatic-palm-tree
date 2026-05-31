{
  lib,
  self,
  inputs,
  config,
  ...
}: let
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};

  # ── Schema module re-used in several evalModules dry-runs ──────────────────
  unfreeOptionsModule = {
    options.unfree = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
    };
  };

  # ── Only build standalone HM configurations for non-NixOS hosts ────────────
  hmHosts = lib.filterAttrs (_: h: !(h.config.isNixOS or false)) config.discoveredHosts;

  # ── Helpers ─────────────────────────────────────────────────────────────────

  hostHmModules = host:
    lib.flatten [
      (host.modules.home or [])
      (host.modules.shared or [])
    ];

  resolveHomeFeatures = host: let
    relevant =
      lib.filter
      (f:
        featuresLib.discoveredFeatures ? ${f}
        && featuresLib.discoveredFeatures.${f} ? home)
      (host.features or []);
  in
    featuresLib.resolve relevant "home";

  extractUnfree = modulePaths:
    lib.evalModules {
      modules =
        modulePaths
        ++ [
          unfreeOptionsModule
          {_module.check = false;}
        ];
      specialArgs = {
        pkgs = throw "'unfree' lists must be static — they cannot reference pkgs.";
        pkgsUnstable = throw "'unfree' lists must be static — they cannot reference pkgsUnstable.";
        inherit lib;
        config = {};
        options = {};
        inputs = {};
        self = {};
      };
    };

  # ── Build one homeConfiguration for a single (hostname, user) pair ─────────
  mkHomeConfig = hostname: h: user: let
    host = h.config;

    homeFeaturesData = resolveHomeFeatures host;

    perUserModPath = self + /hosts/${hostname}/home-${user}.nix;
    perUserMod = lib.optional (builtins.pathExists perUserModPath) perUserModPath;

    userModulePaths = featuresLib.resolveUserModules (self + /hosts) hostname host.usernames;
    userUnfree = extractUnfree userModulePaths;

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      homeFeaturesData.unfree
      userUnfree.config.unfree
    ]);

    pkgs = pkgsLib.mkPkgs host.system allUnfree;
    pkgsUnstable = pkgsLib.mkPkgsUnstable host.system allUnfree;

    # ── Module group ──────────────────────────────────────────────────────────

    baseModule = {
      imports = lib.flatten [
        homeFeaturesData.modules
        (hostHmModules host)
        perUserMod
      ];

      home.username = user;
      home.homeDirectory = "/home/${user}";
      targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);
    };
  in
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = lib.flatten [
        unfreeOptionsModule
        ../nix-settings.nix
        self.flakeModules.home-manager
        baseModule
      ];
      extraSpecialArgs = {
        inherit pkgsUnstable inputs self;
        inherit (host) usernames;
        pkgsStable = pkgs;
      };
    };

  # ── Build all home configurations across all non-NixOS hosts ───────────────
  allHomeConfigs =
    lib.foldl' lib.recursiveUpdate {}
    (lib.mapAttrsToList
      (hostname: h:
        lib.listToAttrs
        (map
          (user: lib.nameValuePair "${user}@${h.name}" (mkHomeConfig hostname h user))
          h.config.usernames))
      hmHosts);
in {
  imports = [../discovery.nix];

  flake.homeConfigurations = allHomeConfigs;
}
