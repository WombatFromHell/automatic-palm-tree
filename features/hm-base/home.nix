{pkgs, ...}: {
  home.packages = with pkgs; [
    # CLI utilities
    pkgs.unstable.atuin
    bat
    eza
    fd
    fzf
    nvd
    pv
    rdfind
    ripgrep
    starship
    topgrade
    tuckr
    zoxide

    # linux-only packages
    btdu
    duperemove
    fish
    helix
    ncdu
    squashfuse
    pkgs.unstable.yazi
  ];
}
