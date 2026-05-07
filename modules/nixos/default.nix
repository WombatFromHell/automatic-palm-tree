# Base NixOS module — common settings for all NixOS hosts.
# NOTE: allowUnfreePredicate is set per-pkgs-input via builders/default.nix.
# Having both allowUnfree and allowUnfreePredicate is an error — allowUnfree wins silently.
{username, ...}: {
  users.users.${username} = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager"];
  };

  system.stateVersion = "24.11";
}
