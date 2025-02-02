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
    ./modules/openrgb/lightsout-home.nix
    ./modules/surround
    ./veridian.nix # veridian-controller service
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
    openrgb
    firefox
    kdePackages.kate
    kdePackages.kcalc
    protonplus
    zellij
    mangohud
    mpv
    stow
    lazygit
    yazi
    rdfind
    ripgrep
    zoxide
    # include some tools for mason
    python3
    nodejs_23
    pnpm
    gcc
    nil
    gnumake
    alejandra
    statix
  ];

  programs = {
    ghostty.enable = true;
    home-manager.enable = true;
  };
  services = {
    virtual-surround.enable = true;
    lightsout-home.enable = true;
  };
}
