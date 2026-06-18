{
  lib,
  pkgs,
  osUsernames,
  ...
}: {
  system.stateVersion = "25.11";

  programs.fish.enable = lib.mkDefault true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  users.users = lib.genAttrs osUsernames (_: {
    shell = lib.mkOverride 50 pkgs.fish;
  });
}
