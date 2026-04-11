# Base NixOS module — common settings for all NixOS hosts.
{
  pkgs,
  lib,
  self,
  hostArgs,
  ...
}: {
  imports = [../core];

  networking.hostName = lib.mkDefault hostArgs.hostname;

  nixpkgs.config.allowUnfree = true;

  users.users.${hostArgs.username} = {
    isNormalUser = true;
    uid = hostArgs.myuid;
    extraGroups = ["wheel" "networkmanager"];
  };

  system.stateVersion = "24.11";
}
