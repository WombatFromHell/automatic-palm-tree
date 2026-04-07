{
  pkgs,
  hostArgs,
  ...
}: let
  user = hostArgs.username;
  isDarwin = builtins.elem hostArgs.system [
    "x86_64-darwin"
    "aarch64-darwin"
  ];
in {
  home = {
    username = user;
    homeDirectory =
      if isDarwin
      then "/Users/${user}"
      else "/home/${user}";
    stateVersion = "24.11";
  };

  home.packages = with pkgs; [
    # CLI utilities
    atuin
    bat
    btdu
    calcurse
    dust
    eza
    fd
    fzf
    gdu
    khal
    lazygit
    libqalculate
    ncdu
    pv
    rdfind
    ripgrep
    shikane
    squashfuse
    tmux
    trash-cli
    tuckr
    vdirsyncer
    yazi
    yt-dlp
    zoxide

    # Editors & shells
    fish
    helix
    starship

    # Dev tools
    alejandra
    ansible
    ansible-lint
    bats
    cachix
    direnv
    gcc
    mise
    nil
    nix-direnv
    nixfmt
    prettier
    python314
    python314Packages.pytest
    ruff
    statix
    ty
    uv

    # Fonts
    nerd-fonts.iosevka
    nerd-fonts.iosevka-term
    nerd-fonts.jetbrains-mono

    # Wake/peripheral
    joystickwake
  ];

  programs = {
    home-manager.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        global = {log_format = "";};
      };
    };
  };

  services = {
    gpg-agent = {
      enable = true;
      pinentry.package = pkgs.pinentry-qt;
      enableSshSupport = true;
      maxCacheTtl = 60480000;
      defaultCacheTtl = 60480000;
    };
  };
}
