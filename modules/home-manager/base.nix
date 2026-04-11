{
  pkgs,
  self,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
  isDarwin = builtins.elem hostArgs.system [
    "x86_64-darwin"
    "aarch64-darwin"
  ];
in {
  home = {
    username = user;
    homeDirectory =
      if isDarwin
      then "/Users/${user}"
      else "/home/${user}";
    stateVersion = "24.11";
    sessionVariables.FLAKE = "${self.outPath}";
  };

  home.packages = with pkgs; [
    # CLI utilities
    atuin
    bat
    btdu
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
    shikane
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
