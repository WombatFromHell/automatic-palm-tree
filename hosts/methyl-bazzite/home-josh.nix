{
  self,
  pkgs,
  pkgsUnstable,
  ...
}: {
  imports = [
    self.flakeModules.home-manager
    (self.flakeModules.home-manager + "/dev.nix")
    (self.flakeModules.home-manager + "/gpg.nix")
  ];

  home.packages = with pkgsUnstable; [
    calcurse
    khal
    libqalculate
    trash-cli
    vdirsyncer
    yt-dlp
  ];

  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
