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

  # ── Only build NixOS configurations for hosts that set isNixOS = true ──────
  nixosHosts = lib.filterAttrs (_: h: h.config.isNixOS or false) config.discoveredHosts;

  hostNixosModules = host:
    lib.flatten [
      (host.modules.nixos or [])
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

  # ── Build one nixosConfiguration ───────────────────────────────────────────
  mkNixosConfig = name: h: let
    host = h.config;

    nixosFeaturesData = resolveFeatures host "nixos";
    homeFeaturesData = resolveFeatures host "home";

    userModulePaths = featuresLib.resolveUserModules (self + /hosts) name host.usernames;
    userUnfree = helpers.extractUnfree helpers.mkUnfreeOptionsModule userModulePaths;

    allUnfree = lib.unique (lib.flatten [
      (host.unfree or [])
      nixosFeaturesData.unfree
      homeFeaturesData.unfree
      userUnfree.config.unfree
    ]);

    pkgsUnstable = pkgsLib.mkPkgs inputs.nixpkgs-unstable host.system allUnfree;

    # ── Module groups ──────────────────────────────────────────────────────────

    baseModule = {
      imports = lib.flatten nixosFeaturesData.modules;
      nixpkgs = {
        hostPlatform = host.system;
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allUnfree;
      };

      _module.args = {
        inherit pkgsUnstable;
        hostConfig = host;
      };
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
            (helpers.hostHmModules host)
            perUserMod
            helpers.mkUnfreeOptionsModule
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
        helpers.mkUnfreeOptionsModule
        ../nix-settings.nix
        baseModule
        self.flakeModules.nixos
        # detsys' nix binary only enabled if attr 'bootstrap = false;' set on outputs
        (lib.optional (!host.bootstrap) inputs.determinate.nixosModules.default)
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
