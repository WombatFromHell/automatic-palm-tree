_: {
  system = "x86_64-linux";
  username = "josh";
  isNixOS = false;
  unfreeStable = [];
  unfreeUnstable = [];

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
  ];

  home = {
    pkgs,
    pkgsUnstable,
    ...
  }: {
    home.packages = with pkgsUnstable; [
      khal
      libqalculate
      trash-cli
      yt-dlp
    ];

    services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
  };
}
