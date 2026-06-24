{
  lib,
  pkgs,
  config,
  hostConfig,
  ...
}: {
  users.users = lib.genAttrs hostConfig.osUsernames (username: let
    userCfg = hostConfig.users.${username} or {};
    featureExtraGroups = config.extraGroups or [];
  in {
    isNormalUser = true;
    home = "/home/${username}";
    shell = lib.mkOverride 50 pkgs.fish;
    extraGroups =
      ["networkmanager"]
      ++ lib.optional (userCfg.isAdmin or false) "wheel"
      ++ lib.optionals (userCfg.isAdmin or false) featureExtraGroups;
  });
}
