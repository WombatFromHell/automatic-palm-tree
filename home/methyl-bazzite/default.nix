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
    dust
    eza
    fd
    fish
    fzf
    joystickwake
    lazygit
    neovim
    pv
    rdfind
    ripgrep
    spicetify-cli
    starship
    tuckr
    tmux
    yazi
    zoxide
    # include some tools for dev work
    direnv
    nix-direnv
    gcc
    nil
    rustup
    alejandra
    python3
    statix
  ];

  programs = {
    gpg.enable = true;
    home-manager.enable = true;
  };
  services = {
    gpg-agent = {
      enable = true;
      pinentryPackage = pkgs.pinentry-qt;
      enableSshSupport = true;
      maxCacheTtl = 60480000;
      defaultCacheTtl = 60480000;
    };
  };
}
