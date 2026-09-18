{
  pkgs,
  pkgsUnstable,
  ...
}: {
  home.packages = with pkgsUnstable; [
    heroic
    khal
    libqalculate
    trash-cli
  ];

  features = {
    dms.niriCompat = true;
    niri = {
      niri-watcher.enable = true;
    };
    oomd.notify = true;
  };
}
