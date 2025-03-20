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
    bat
    eza
    fd
    fish
    fzf
    lazygit
    neovim
    rdfind
    ripgrep
    spicetify-cli
    starship
    tuckr
    yazi
    zoxide
    # include some tools for mason
    nil
    alejandra
    statix
  ];

  programs = {
    home-manager.enable = true;
  };
}
