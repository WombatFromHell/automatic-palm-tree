_: let
  myHome = {
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

    features = {
      zed-editor.enable = true;
    };

    services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
  };
in {
  system = "x86_64-linux";
  isNixOS = false;

  features = [
    "hm-base"
    "hm-dev"
    "hm-gpg"
    "hm-media"
    "hm-nh"
    #
    "hm-nixgl"
    #
    "hm-zed"
  ];

  homeModules.josh = [myHome];
}
