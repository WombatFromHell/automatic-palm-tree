{
  pkgsStable,
  pkgsUnstable,
  lib,
  ...
}: let
  inherit (pkgsStable.stdenv) isDarwin;
in {
  home.stateVersion = "24.11";

  home.packages = with pkgsStable;
    [
      # CLI utilities
      pkgsUnstable.atuin
      bat
      eza
      fd
      fzf
      lazygit
      pv
      rdfind
      ripgrep
      starship
      tmux
      tuckr
      zoxide
    ]
    ++ lib.optionals (!isDarwin) [
      # linux-only packages
      btdu
      fish
      helix
      ncdu
      squashfuse
      yazi
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
