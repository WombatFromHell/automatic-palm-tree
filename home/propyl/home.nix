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
    nerd-fonts.iosevka
    nerd-fonts.iosevka-term
    #
    direnv
    nix-direnv
    #
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
    tmux
    stow
    lazygit
    yazi
    rdfind
    ripgrep
    zoxide
    #
    kitty
    # include some tools for mason
    gcc
    nil
    alejandra
    python3
    statix
  ];

  programs = {
    home-manager.enable = true;
  };
}
