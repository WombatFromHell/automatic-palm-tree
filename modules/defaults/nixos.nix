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
    isAdmin = userCfg.isAdmin or false;
    featureExtraGroups = lib.concatLists (lib.attrValues config.extraGroups);
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
