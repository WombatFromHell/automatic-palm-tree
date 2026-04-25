# modules/darwin/default.nix
_: {
  nix.enable = true;

  programs = {
    zsh.enable = true;
    fish.enable = true;
  };

  security.pam.services.sudo_local.touchIdAuth = true;
  system.stateVersion = 6;
}
