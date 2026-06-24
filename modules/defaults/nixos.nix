{
  lib,
  pkgs,
  ...
}: {
  system.stateVersion = "25.11";
  programs.fish.enable = lib.mkDefault true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
