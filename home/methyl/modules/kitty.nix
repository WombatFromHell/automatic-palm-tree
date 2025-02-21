{config, ...}: {
  programs.kitty.enable = true;
  # don't overwrite our existing dotfiles
  xdg.configFile."kitty/kitty.conf".force = false;
}
