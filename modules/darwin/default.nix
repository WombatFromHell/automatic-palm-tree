# modules/darwin/default.nix
_: {
  nix.enable = false;

  programs = {
    zsh.enable = true;
    fish.enable = true;
  };

  security.pam.services.sudo_local.touchIdAuth = true;
  system.stateVersion = 6;
}
