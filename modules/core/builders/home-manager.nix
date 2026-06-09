{
  lib,
  self,
  inputs,
  config,
  ...
}: let
  pkgsLib = import ../pkgs.nix {inherit lib inputs;};
  featuresLib = import ../features.nix {inherit lib self;};
  helpers = import ../helpers.nix {inherit lib inputs self;};

  # ── Only build standalone HM configurations for non-NixOS hosts ────────────
  hmHosts = lib.filterAttrs (_: h: !(h.config.isNixOS or false)) config.discoveredHosts;

  resolveHomeFeatures = host: let
    relevant =
      lib.filter
      (f:
        featuresLib.discoveredFeatures ? ${f}
        && featuresLib.discoveredFeatures.${f} ? "home")
      (host.features or []);
  in
    featuresLib.resolve relevant "home" host;

  # ── Build one homeConfiguration for a single (hostname, user) pair ─────────
  mkHomeConfig = hostname: h: user: let
    host = h.config;

    homeFeaturesData = resolveHomeFeatures host;

    perUserModPath = self + /hosts/${hostname}/home-${user}.nix;
    perUserMod = lib.optional (builtins.pathExists perUserModPath) perUserModPath;

    userModulePaths = featuresLib.resolveUserModules (self + /hosts) hostname host.usernames;
    userUnfree = helpers.extractUnfree helpers.mkUnfreeOptionsModule userModulePaths;

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      homeFeaturesData.unfree
      userUnfree.config.unfree
    ]);

    pkgs = pkgsLib.mkPkgs inputs.nixpkgs host.system allUnfree [inputs.nixgl.overlay];
    pkgsUnstable = pkgsLib.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];

    # ── Module group ──────────────────────────────────────────────────────────

    baseModule = {
      imports = lib.flatten [
        homeFeaturesData.modules
        (helpers.hostHmModules host)
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
        helpers.mkUnfreeOptionsModule
        ../nix-settings.nix
        self.flakeModules.home-manager
        baseModule
      ];

      extraSpecialArgs = {
        inherit pkgsUnstable inputs self;
        pkgsStable = pkgs;
        hostConfig = host;
        inherit (inputs) nixgl;
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
