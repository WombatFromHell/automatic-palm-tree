{pkgs, ...}: {
  home.packages = with pkgs; [
    spotify
    neovim
    rustup
    zstd
    gawk
    git
    kitty
    python3
  ];

  programs = {
    nh.enable = true;
  };
}
