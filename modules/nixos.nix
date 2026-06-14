{
  lib,
  pkgs,
  osUsernames,
  ...
}: {
  system.stateVersion = "25.11";

  programs.fish.enable = lib.mkDefault true;
  users.users = lib.genAttrs osUsernames (_: {
    shell = lib.mkOverride 50 pkgs.fish;
  });
}
