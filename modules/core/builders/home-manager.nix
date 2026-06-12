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
    resolveFeatures
    collectUnfree
    hostHmModules
    mkUnstablePkgs
    perUserModulePaths
    mkUserHomeModule
    ;

  hmHosts = lib.filterAttrs (_: h: let
    host = h.config;
  in
    !(host.isNixOS or false))
  config.discoveredHosts;

  mkHomeConfig = h: user: userModulePaths: let
    host = h.config;

    homeFeaturesData = resolveFeatures host "home";

    allUnfree = collectUnfree host [homeFeaturesData] userModulePaths;

    pkgs = pkgsLib.mkPkgs inputs.nixpkgs host.system allUnfree [inputs.nixgl.overlay];
    pkgsUnstable = mkUnstablePkgs host allUnfree;

    baseModule = {
      imports = [
        (mkUserHomeModule {
          inherit lib pkgsLib self user homeFeaturesData;
          hostHmModules = hostHmModules host;
          perUserMod = host.modules.perUser.${user} or [];
        })
        {targets.genericLinux.enable = lib.mkDefault (!host.isNixOS);}
      ];
    };
  in
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = lib.flatten [
        ../nix-settings.nix
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
      (_: h: let
        host = h.config;
        userModulePaths = perUserModulePaths host;
      in
        lib.listToAttrs
        (map
          (user: lib.nameValuePair "${user}@${h.name}" (mkHomeConfig h user userModulePaths))
          host.hmUsernames))
      hmHosts);
in {
  imports = [../discovery.nix];
  flake.homeConfigurations = allHomeConfigs;
}
