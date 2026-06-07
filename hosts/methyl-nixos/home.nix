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
    dms.enable = true;
    kanshi.enable = true;
    niri-watcher.enable = true;
    dmemcg-booster.enable = true;
    #
    oomd.notify = true;
  };

  programs.gpg.enable = true;
  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
