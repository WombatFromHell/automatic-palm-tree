{
  lib,
  pkgs,
  usernames,
  ...
}: {
  system.stateVersion = "25.11";

  programs.fish.enable = lib.mkDefault true;
  users.users = lib.genAttrs usernames (_: {
    shell = lib.mkOverride 50 pkgs.fish;
  });
}
