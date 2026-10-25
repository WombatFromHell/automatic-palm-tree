{pkgs, ...}: {
  home.packages = with pkgs.unstable; [
    heroic
    libqalculate
    trash-cli
  ];

  features = {
    niri = {
      wl-watcher.enable = true;
    };
    oomd.notify = true;
    tmux-git.enable = true;
  };
}
