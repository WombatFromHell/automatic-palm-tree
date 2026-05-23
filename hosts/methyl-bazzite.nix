{self, ...}: {
  system = "x86_64-linux";
  username = "josh";
  isNixOS = false;
  unfreeStable = [];
  unfreeUnstable = [];

  imports = [
    self.flakeModules.home-manager
    (self.flakeModules.home-manager + "/dev.nix")
    (self.flakeModules.home-manager + "/gpg.nix")
  ];

  home = {
    pkgs,
    pkgsUnstable,
    ...
  }: {
    home.packages = with pkgsUnstable; [
      calcurse
      khal
      libqalculate
      trash-cli
      vdirsyncer
      yt-dlp
    ];

    services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
  };
}
