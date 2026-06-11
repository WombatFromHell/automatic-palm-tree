{
  self,
  lib,
  inputs,
  config,
  ...
}: let
  shared = import ./shared.nix {inherit lib self inputs;};
  inherit
    (shared)
    pkgsLib
    featuresLib
    resolveFeatures
    collectUnfree
    hostHmModules
    ;

  hmHosts = lib.filterAttrs (_: h: !(h.config.isNixOS or false)) config.discoveredHosts;

  mkHomeConfig = hostname: h: user: userModulePaths: let
    host = h.config;

    homeFeaturesData = resolveFeatures host "home";
    perUserMod = host.modules.perUser.${user} or [];

    allUnfree = collectUnfree host [homeFeaturesData] userModulePaths;

    pkgs = pkgsLib.mkPkgs inputs.nixpkgs host.system allUnfree [inputs.nixgl.overlay];
    pkgsUnstable = pkgsLib.mkPkgs inputs.nixpkgs-unstable host.system allUnfree [];

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
        pkgsLib.mkUnfreeOptionsModule
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

  allHomeConfigs =
    lib.foldl' lib.recursiveUpdate {}
    (lib.mapAttrsToList
      (hostname: h: let
        userModulePaths = lib.concatLists (lib.attrValues (h.config.modules.perUser or {}));
      in
        lib.listToAttrs
        (map
          (user: lib.nameValuePair "${user}@${h.name}" (mkHomeConfig hostname h user userModulePaths))
          h.config.usernames))
      hmHosts);
in {
  imports = [../discovery.nix];
  flake.homeConfigurations = allHomeConfigs;
}
