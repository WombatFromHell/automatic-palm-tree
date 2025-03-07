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
    direnv
    nix-direnv
    dust
    #
    bat
    eza
    fd
    fish
    fzf
    lazygit
    rdfind
    ripgrep
    starship
    stow
    zoxide
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
