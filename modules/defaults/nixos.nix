{
  lib,
  pkgs,
  config,
  hostConfig,
  ...
}: {
  system.stateVersion = "25.11";
  programs.fish.enable = lib.mkDefault true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  users.users = lib.genAttrs hostConfig.osUsernames (username: let
    userCfg =
      if builtins.hasAttr username hostConfig.users
      then hostConfig.users.${username}
      else {};
    isAdmin = builtins.hasAttr "isAdmin" userCfg && userCfg.isAdmin;
    featureExtraGroups =
      if builtins.hasAttr "extraGroups" config
      then config.extraGroups
      else [];
  in {
    isNormalUser = true;
    home = "/home/${username}";
    shell = lib.mkOverride 50 pkgs.fish;
    extraGroups =
      ["networkmanager"]
      ++ lib.optional isAdmin "wheel"
      ++ lib.optionals isAdmin featureExtraGroups;
  });
}
