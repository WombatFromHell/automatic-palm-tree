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
    nerd-fonts.jetbrains-mono
    nerd-fonts.monaspace
    nerd-fonts.iosevka
    nerd-fonts.iosevka-term
    #
    direnv
    nix-direnv
    wl-clipboard
    git
    dust
    fzf
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
    zellij
    mangohud
    mpv
    stow
    lazygit
    yazi
    rdfind
    ripgrep
    zoxide
    vesktop
    rustmission
    code-cursor
    # include some tools for mason
    nil
    alejandra
    python3
    statix
  ];

  programs = {
    # disabled due to startup lag
    # ghostty.enable = true;
    #
    alacritty.enable = true;
    home-manager.enable = true;
  };

  # user-defined HM module enablement
  theming.enable = true;
  virtual-surround.enable = true;
  services = {
    # nixos 'services.lightsout.enable' is required here as well
    lightsout.enable = true;
    monitor-session.enable = true;
  };
}
