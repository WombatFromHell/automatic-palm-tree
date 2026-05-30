{
  lib,
  pkgs,
  usernames,
  ...
}: {
  system.stateVersion = "24.11";

  programs.fish.enable = lib.mkDefault true;
  users.users = lib.genAttrs usernames (_: {
    shell = lib.mkDefault pkgs.fish;
  });
}
