{
  pkgs,
  pkgsUnstable,
  ...
}: {
  home.packages = with pkgs; [
    # CLI utilities
    pkgsUnstable.atuin
    bat
    eza
    fd
    fzf
    nvd
    pv
    rdfind
    ripgrep
    starship
    tmux
    tuckr
    zoxide

    # linux-only packages
    btdu
    fish
    helix
    ncdu
    squashfuse
    pkgsUnstable.yazi
  ];
}
