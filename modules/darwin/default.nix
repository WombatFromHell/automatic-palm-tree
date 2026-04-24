# modules/darwin/default.nix
{
  pkgs,
  lib,
  config,
  ...
}: {
  users.users =
    lib.mapAttrs (_: _: {
      shell = pkgs.fish;
    })
    config.home-manager.users;

  nix.enable = false;

  # home is set automatically by home-manager when useUserPackages = true
  programs = {
    zsh.enable = true;
    fish.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
  };

  security.pam.services.sudo_local.touchIdAuth = true;
  system.stateVersion = 6;
}
