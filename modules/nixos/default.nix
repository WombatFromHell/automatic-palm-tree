{username, ...}: {
  users.users.${username} = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager"];
  };

  system.stateVersion = "24.11";
}
