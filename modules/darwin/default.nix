# modules/darwin/default.nix
_: {
  # don't allow 'nix' binary to be managed via flake
  nix.enable = false;

  programs = {
    zsh.enable = true;
    fish.enable = true;
  };

  security.pam.services.sudo_local.touchIdAuth = true;
  system.stateVersion = 6;
}
