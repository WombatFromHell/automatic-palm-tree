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
    # browsers
    brave
    firefox
    # terminal
    kitty
    # kde apps
    kdePackages.kate
    kdePackages.kcalc
    # media
    mpv
    # system / hardware
    btop
    mangohud
    openrgb
    wl-clipboard
    # misc
    gawk
    git
    stow
    unzip
    vesktop
  ];

  # user-defined HM module enablement
  theming.enable = true;
  virtual-surround.enable = true;
  services = {
    lightsout.enable = true;
    monitor-session.enable = true;
  };

  # enable kwallet's pinentry agent support api
  xdg.configFile."kwalletrc".text = ''
    [Wallet]
    First Use=false
    [org.freedesktop.secrets]
    apiEnabled=true
  '';
}
