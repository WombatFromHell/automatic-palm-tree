{
  pkgs,
  lib,
  config,
  self,
  ...
}: let
  user = config.home.username;
  inherit (pkgs.stdenv) isDarwin;
in {
  home = {
    homeDirectory =
      if isDarwin
      then "/Users/${user}"
      else "/home/${user}";
    stateVersion = "24.11";
    sessionVariables.FLAKE = "${self.outPath}";
  };

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
    ++ lib.optionals (!isDarwin) [
      # Linux-only
      btdu
    ];

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
