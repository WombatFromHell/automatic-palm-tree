# Base NixOS module — common settings for all NixOS hosts.
{username, ...}: {
  nixpkgs.config.allowUnfree = true;

  users.users.${username} = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager"];
  };

  system.stateVersion = "24.11";
}
