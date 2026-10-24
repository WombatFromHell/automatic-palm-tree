{pkgs, ...}: {
  home.packages = with pkgs.unstable; [
    heroic
    libqalculate
    trash-cli
  ];

  features = {
    dms.niriCompat = true;
    niri = {
      niri-watcher.enable = true;
    };
    oomd.notify = true;
    tmux-git.enable = true;
  };
}
