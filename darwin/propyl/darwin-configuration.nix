{
  pkgs,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
in {
  nix = {
    gc = {
      automatic = true;
      interval.Day = 7;
      options = "--delete-older-than 7d";
    };
    optimise = {
      automatic = true;
      dates = ["09:00"];
    };
    settings = {
      experimental-features = ["nix-command" "flakes"];
      substituters = [
        "https://nix-community.cachix.org/"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
  };

  users.users.${user} = {
    home = "/Users/${user}";
    shell = pkgs.fish;
  };

  programs = {
    zsh.enable = true;
    fish.enable = true;
    kitty.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
  };

  nixpkgs.config.allowUnfree = true;
  # enable TouchID support for sudo
  security.pam.enableSudoTouchIdAuth = true;

  system.stateVersion = "24.11";
}
