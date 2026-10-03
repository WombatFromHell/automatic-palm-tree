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
      tmux-git.enable = true;
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
    "hm-agenix"
    #
    "hm-nixgl"
    #
    "hm-brave"
    "hm-zed"
    #
    "hm-tmux"
  ];

  homeModules.josh = [myHome];
}
