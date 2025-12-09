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
    homeDirectory = "/home/${user}";
    stateVersion = "24.11";
  };

  home.packages = with pkgs; [
    bat
    btdu
    dust
    eza
    fd
    fish
    fzf
    gdu
    helix
    sysz
    atuin
    joystickwake
    lazygit
    ncdu
    neovim
    pv
    rdfind
    ripgrep
    starship
    tuckr
    tmux
    yazi
    yt-dlp
    zoxide
    # include some tools for dev work
    ansible
    ansible-lint
    cachix
    direnv
    nix-direnv
    gcc
    nil
    rustup
    alejandra
    python3
    statix
    uv
  ];

  programs = {
    gpg.enable = true;
    home-manager.enable = true;
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
