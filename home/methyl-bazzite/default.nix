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
    atuin
    bat
    btdu
    calcurse
    dust
    eza
    fd
    fish
    fzf
    gdu
    helix
    joystickwake
    khal
    lazygit
    libqalculate
    ncdu
    pv
    rdfind
    ripgrep
    starship
    squashfuse
    tmux
    tuckr
    vdirsyncer
    yazi
    zoxide
    # include some tools for dev work
    alejandra
    ansible
    ansible-lint
    bats
    cachix
    direnv
    nix-direnv
    mise
    nil
    nixfmt
    prettier
    python314
    python314Packages.pytest
    ruff
    statix
    ty
    uv
  ];

  programs = {
    gpg.enable = true;
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
