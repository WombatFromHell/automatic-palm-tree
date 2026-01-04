{
  pkgs,
  hostArgs,
  ...
}:
let
  user = hostArgs.username;
in
{
  home = {
    username = user;
    homeDirectory = "/home/${user}";
    stateVersion = "24.11";
  };

  home.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.iosevka
    nerd-fonts.iosevka-term
    #
    direnv
    nix-direnv
    wl-clipboard
    git
    dust
    fzf
    helix
    eza
    bat
    fd
    pv
    gawk
    btop
    unzip
    openrgb
    firefox
    kdePackages.kate
    kdePackages.kcalc
    tmux
    mangohud
    mpv
    ncdu
    squashfuse
    stow
    lazygit
    neovim
    yazi
    rdfind
    ripgrep
    zoxide
    vesktop
    rustmission
    code-cursor
    kitty
    brave
    # include some tools for mason
    alejandra
    bats
    gcc
    kcov
    nil
    python3
    statix
    uv
    ty
  ];

  programs = {
    home-manager.enable = true;
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
