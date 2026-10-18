{
  lib,
  pkgs,
  config,
  ...
}: {
  system.stateVersion = "25.11";
  networking.hostName = lib.mkDefault config.flakeHost.name;
  programs.fish.enable = lib.mkDefault true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  users.users = lib.genAttrs config.flakeHost.osUsernames (username: let
    userCfg = config.flakeHost.users.${username} or {};
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
