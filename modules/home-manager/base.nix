{
  pkgs,
  lib,
  config,
  self,
  hostArgs,
  ...
}: let
  user = config.home.username;
  isDarwin = pkgs.stdenv.isDarwin;
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

  services = {
    gpg-agent = {
      enable = true;
      enableSshSupport = true;
      maxCacheTtl = 60480000;
      defaultCacheTtl = 60480000;
    };
  };
}
