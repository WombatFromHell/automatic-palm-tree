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
    theming.enable = true;
    dms = {
      enable = true;
      niriCompat = true;
    };
    niri = {
      niri-watcher.enable = true;
      kanshi.enable = false;
    };
    dcal.enableService = false;
    dmemcg-booster.enable = true;
    zed-editor.enable = true;
    nasmount.enable = true;
    syncthing.enable = true;
    #
    oomd.notify = true;
  };
}
