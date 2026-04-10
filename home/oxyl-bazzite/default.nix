{pkgs, ...}: {
  home.packages = with pkgs; [
    neovim
    spicetify-cli
    python3
  ];
}
