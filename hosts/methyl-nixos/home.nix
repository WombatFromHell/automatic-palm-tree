{
  pkgs,
  pkgsUnstable,
  ...
}: {
  home.packages = with pkgsUnstable; [
    khal
    libqalculate
    trash-cli
  ];

  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
