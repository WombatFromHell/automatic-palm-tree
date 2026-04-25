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
      eza
      fd
      fzf
      gdu
      lazygit
      ncdu
      pv
      rdfind
      ripgrep
      squashfuse
      starship
      tmux
      tuckr
      yazi
      zoxide
    ]
    ++ lib.optionals (!isDarwin) [
      # linux-only packages
      btdu
      calcurse
      dust
      fish
      helix
      khal
      libqalculate
      trash-cli
      vdirsyncer
      yt-dlp
    ];

  programs = {
    home-manager.enable = true;
    nh.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = !isDarwin;
      config = {
        global = {log_format = "";};
      };
    };
  };
}
