_: let
  myHome = {
    pkgs,
    pkgsUnstable,
    ...
  }: {
    home.packages = with pkgs; [
      pkgsUnstable.yt-dlp
      #
      trash-cli
      zellij
    ];

    features = {
      zed-editor.enable = true;
      dcal.enableService = false;
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
    "hm-dcal"
    "hm-xilo"
    #
    "hm-nixgl"
    #
    "hm-zed"
  ];

  homeModules.josh = [myHome];
}
