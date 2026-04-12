# Base Darwin module — common settings for all macOS hosts.
{
  pkgs,
  lib,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
in {
  imports = [../core];

  nixpkgs.config.allowUnfree = true;

  networking.computerName = lib.mkDefault hostArgs.hostname;
  networking.hostName = lib.mkDefault hostArgs.hostname;

  users.users.${user} = {
    home = "/Users/${user}";
    shell = pkgs.fish;
  };

  programs = {
    zsh.enable = true;
    fish.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
  };

  # enable TouchID support for sudo
  security.pam.services.sudo_local.touchIdAuth = true;

  system.stateVersion = 6;
}
