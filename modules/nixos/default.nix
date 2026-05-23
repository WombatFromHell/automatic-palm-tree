# modules/nixos/default.nix
{username, ...}: {
  # Binary Caches
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    bash-prompt-prefix = "(nix:$name) ";
    substituters = [
      "https://cache.nixos.org"
      "https://wombatfromhell.cachix.org/"
      "https://nix-community.cachix.org/"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "wombatfromhell.cachix.org-1:pyIVJJkoLxkjH/MKK1ylrrdJKPpm+aXLeD2zAqVk9lA="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  documentation = {
    enable = false;
    man.enable = false;
  };

  users.users.${username} = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager"];
  };

  system.stateVersion = "24.11";
}
