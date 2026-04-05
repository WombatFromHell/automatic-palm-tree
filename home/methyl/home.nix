{
  pkgs,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
in {
  home = {
    username = user;
    homeDirectory = "/home/${user}";
    stateVersion = "24.11";
  };

  home.packages = with pkgs; [
    nerd-fonts.iosevka
    nerd-fonts.iosevka-term
    nerd-fonts.jetbrains-mono
    #
    bat
    brave
    btop
    direnv
    dust
    eza
    fd
    firefox
    fzf
    gawk
    git
    helix
    kdePackages.kate
    kdePackages.kcalc
    kitty
    lazygit
    libqalculate
    mangohud
    mpv
    ncdu
    nix-direnv
    openrgb
    pv
    rdfind
    ripgrep
    squashfuse
    stow
    tmux
    vdirsyncer
    vesktop
    wl-clipboard
    unzip
    yazi
    zoxide
    # include some tools for mason
    alejandra
    bats
    gcc
    mise
    nil
    nixfmt
    prettier
    python314
    python314Packages.pytest
    ruff
    statix
    ty
    uv
  ];

  programs = {
    home-manager.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        global = {log_format = "";};
      };
    };
  };

  # user-defined HM module enablement
  theming.enable = true;
  virtual-surround.enable = true;
  services = {
    lightsout.enable = true;
    monitor-session.enable = true;
  };

  # enable kwallet's pinentry agent support api
  xdg.configFile."kwalletrc".text = ''
    [Wallet]
    First Use=false
    [org.freedesktop.secrets]
    apiEnabled=true
  '';
}
