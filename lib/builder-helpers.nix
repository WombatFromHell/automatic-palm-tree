{
  lib,
  self,
}: let
  featuresLib = import ./features.nix {inherit lib self;};

  mkPkgs = pkgsInput: system: unfree: overlays:
    import pkgsInput {
      inherit system overlays;
      config.allowUnfreePredicate = let
        u = builtins.listToAttrs (map (n: {
            name = n;
            value = true;
          })
          unfree);
      in
        pkg: u ? ${lib.getName pkg};
    };

  resolveHostModules = host: platform:
    (host.modules.${platform} or []) ++ (host.modules.shared or []);

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
  }: {
    imports = lib.flatten [
      host.homeModules
      (resolveHostModules host "home")
      (host.modules.perUser.${user} or [])
      featuresLib.featureOptionsModule
      self.flakeModules.home-manager
    ];
    home.username = user;
    home.homeDirectory = "/home/${user}";
  };
in {
  inherit mkPkgs resolveHostModules mkNixosUserModule mkUserHomeModule;
}
