{
  pkgs,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
in {
  nix.enable = false;

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
  security.pam.enableSudoTouchIdAuth = true;

  system.stateVersion = 6;
}