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
    ];

    features = {
      zed-editor.enable = true;
    };
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
    "hm-xilo"
    "hm-herdr"
    #
    "hm-nixgl"
    #
    "hm-zed"
  ];

  homeModules.josh = [myHome];
}
