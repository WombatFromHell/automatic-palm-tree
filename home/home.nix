{
  pkgs,
  sharedArgs,
  ...
}: let
  user = sharedArgs.username;
in {
  home = {
    username = user;
    homeDirectory = "/home/${user}";
    stateVersion = "24.11";
  };

  imports = [
    ./modules/monitor-session
    ./modules/surround
    ./modules/monitor-session/fix-gsync.nix
    ./modules/openrgb/lightsout-home.nix
    ./modules/veridian.nix
  ];

  home.packages = with pkgs; [
    nerd-fonts.meslo-lg
    nerd-fonts.jetbrains-mono
    nerd-fonts.caskaydia-cove
    direnv
    nix-direnv
    wl-clipboard
    git
    dust
    fzf
    eza
    bat
    fd
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
    # include some tools for mason
    # nodejs_23 # in favor of nvm.fish
    # pnpm # in favor of nvm.fish
    gcc
    # nil # in favor of mason
    gnumake
    alejandra
    statix
    rustup
  ];

  virtual-surround.enable = true;
  veridian-controller.enable = true;
  programs = {
    # disabled due to startup lag
    # ghostty.enable = true;
    #
    alacritty.enable = true;
    home-manager.enable = true;
  };
  services = {
    lightsout-home.enable = true;
    monitor-session.enable = true;
  };
}
