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
    joystickwake
    lazygit
    lm_sensors
    rdfind
    ripgrep
    spicetify-cli
    starship
    tuckr
    yazi
    zoxide
    #
    peazip
    # include some tools for mason
    gcc
    nil
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
