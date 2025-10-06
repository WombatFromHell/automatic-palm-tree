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
    homeDirectory = "/Users/${user}";
    stateVersion = "24.11";
  };

  home.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.iosevka
    nerd-fonts.iosevka-term
    #
    bat
    eza
    fd
    fzf
    gawk
    git
    kitty
    lazygit
    neovim
    pv
    rdfind
    ripgrep
    spotify
    starship
    tmux
    tuckr
    unzip
    yazi
    zoxide
    zstd
    # include some tools for mason
    alejandra
    gcc
    nil
    python3
    statix
    uv
  ];

  programs = {
    gpg.enable = true;
    nh.enable = true;
    home-manager.enable = true;
  };
}
