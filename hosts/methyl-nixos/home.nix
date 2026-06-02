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
    dms.enable = true;
    kanshi.enable = true;
    niri-watcher.enable = true;
  };

  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
