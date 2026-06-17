{
  lib,
  self,
}: let
  featuresLib = import ./features.nix {inherit lib self;};

  resolveHostModules = host: platform:
    if platform == "nixos"
    then (host.nixosModules or []) ++ (host.sharedModules or [])
    else if platform == "home"
    then host.sharedModules or []
    else [];

  mkNixosUserModule = host: {lib, ...}: {
    users.users = lib.genAttrs host.osUsernames (username: let
      userCfg = host.users.${username} or {};
    in {
      isNormalUser = true;
      home = "/home/${username}";
      extraGroups =
        ["networkmanager"]
        ++ lib.optional (userCfg.isAdmin or false) "wheel";
    });
  };

  mkUserHomeModule = {
    user,
    host,
  }: let
    hostFeatures = host.features or [];
    homeFeaturePaths = lib.flatten (
      map (
        f:
          if !(featuresLib.discoveredFeatures ? ${f})
          then throw "Unknown feature '${f}'"
          else let
            feature = featuresLib.discoveredFeatures.${f};
            homeMod = feature.home or null;
            sharedMod = feature.shared or null;
          in
            lib.filter (p: p != null) [homeMod sharedMod]
      )
      hostFeatures
    );
  in {
    imports = lib.flatten [
      homeFeaturePaths
      (resolveHostModules host "home")
      (host.homeModules.${user} or [])
      # Added back so HM users can declare unfreePackages natively!
      featuresLib.featureOptionsModule
      self.flakeModules.home-manager
    ];
    home.username = user;
    home.homeDirectory = "/home/${user}";
  };
in {
  inherit resolveHostModules mkNixosUserModule mkUserHomeModule;
}
