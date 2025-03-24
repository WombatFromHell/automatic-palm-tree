{
  pkgs,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
in {
  home = {
    username = user;
    homeDirectory = "/Users/${user}";
    stateVersion = "24.11";
  };

  home.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.iosevka
    nerd-fonts.iosevka-term
    #
    git
    fzf
    eza
    bat
    fd
    pv
    zstd
    tuckr
    gawk
    unzip
    tmux
    lazygit
    yazi
    kitty
    rdfind
    ripgrep
    zoxide
    neovim
    # include some tools for mason
    gcc
    nil
    alejandra
    python3
    statix
  ];

  programs = {
    gpg.enable = true;
    nh.enable = true;
    home-manager.enable = true;
  };
}
