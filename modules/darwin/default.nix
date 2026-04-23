# Base Darwin module — common settings for all macOS hosts.
{
  pkgs,
  username,
  ...
}: {
  users.users.${username} = {
    home = "/Users/${username}";
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
