{
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isDarwin;
in {
  home.stateVersion = "24.11";

  home.packages = with pkgs;
    [
      # CLI utilities
      atuin
      bat
      calcurse
      dust
      eza
      fd
      fzf
      gdu
      khal
      lazygit
      libqalculate
      ncdu
      pv
      rdfind
      ripgrep
      squashfuse
      tmux
      trash-cli
      tuckr
      vdirsyncer
      yazi
      yt-dlp
      zoxide

      # Editors & shells
      fish
      helix
      starship
    ]
    ++ lib.optionals (!isDarwin) [fish btdu];

  programs = {
    home-manager.enable = true;
    nh.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        global = {log_format = "";};
      };
    };
  };
}
