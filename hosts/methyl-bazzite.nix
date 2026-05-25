{self, ...}: {
  system = "x86_64-linux";
  username = "josh";

  home = {
    pkgs,
    pkgsUnstable,
    ...
  }: {
    imports = [
      self.features.hm-base.home
      self.features.hm-dev.home
      self.features.hm-gpg.home
    ];
    home.packages = with pkgsUnstable; [
      khal
      libqalculate
      trash-cli
      yt-dlp
    ];

    services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
  };
}
