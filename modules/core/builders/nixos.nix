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

  # ── Only build NixOS configurations for hosts that set isNixOS = true ──────
  nixosHosts = lib.filterAttrs (_: h: h.config.isNixOS or false) config.discoveredHosts;

  # ── Helpers ─────────────────────────────────────────────────────────────────

  hostNixosModules = host:
    lib.flatten [
      (host.modules.nixos or [])
      (host.modules.shared or [])
    ];

  hostHmModules = host:
    lib.flatten [
      (host.modules.home or [])
      (host.modules.shared or [])
    ];

  resolveFeatures = host: platform: let
    relevant =
      lib.filter
      (f:
        featuresLib.discoveredFeatures ? ${f}
        && featuresLib.discoveredFeatures.${f} ? ${platform})
      (host.features or []);
  in
    featuresLib.resolve relevant platform;

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

  # ── Build one nixosConfiguration ───────────────────────────────────────────
  mkNixosConfig = name: h: let
    host = h.config;

    nixosFeaturesData = resolveFeatures host "nixos";
    homeFeaturesData = resolveFeatures host "home";

    userModulePaths = featuresLib.resolveUserModules (self + /hosts) name host.usernames;
    userUnfree = extractUnfree userModulePaths;

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      nixosFeaturesData.unfree
      homeFeaturesData.unfree
      userUnfree.config.unfree
    ]);

    pkgsUnstable = pkgsLib.mkPkgsUnstable host.system allUnfree;

    # ── Module groups ──────────────────────────────────────────────────────────

    baseModule = {
      imports = lib.flatten nixosFeaturesData.modules;
      nixpkgs = {
        hostPlatform = host.system;
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allUnfree;
      };
      _module.args = {inherit pkgsUnstable;};
    };

    homeManagerModule = {
      nixpkgs.overlays = [inputs.nix-cachyos-kernel.overlays.default];
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = {inherit pkgsUnstable inputs self;};

        users = lib.genAttrs host.usernames (user: let
          perUserModPath = self + /hosts/${name}/home-${user}.nix;
          perUserMod = lib.optional (builtins.pathExists perUserModPath) perUserModPath;
        in {
          imports = lib.flatten [
            homeFeaturesData.modules
            (hostHmModules host)
            perUserMod
            unfreeOptionsModule
            self.flakeModules.home-manager
            {
              home.username = user;
              home.homeDirectory = "/home/${user}";
            }
          ];
        });
      };
    };
  in
    inputs.nixpkgs.lib.nixosSystem {
      modules = lib.flatten [
        unfreeOptionsModule
        ../nix-settings.nix
        baseModule
        self.flakeModules.nixos
        # uncomment determinate flake module after initial deployment (for caching)
        #inputs.determinate.nixosModules.default
        (hostNixosModules host)
        inputs.home-manager.nixosModules.home-manager
        homeManagerModule
      ];

      specialArgs = {
        inherit inputs self;
        inherit (host) usernames;
        mkUser = {groups ? [], ...} @ args:
          (removeAttrs args ["groups"])
          // {
            isNormalUser = true;
            extraGroups = ["wheel" "networkmanager"] ++ groups;
          };
      };
    };
in {
  imports = [../discovery.nix];

  flake.nixosConfigurations = lib.mapAttrs mkNixosConfig nixosHosts;
}
