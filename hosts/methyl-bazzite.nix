_: let
  myHome = {pkgs, ...}: {
    home.packages = with pkgs; [
      pkgs.unstable.yt-dlp
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
    "hm-xilo"
    "hm-herdr"
    "hm-agenix"
    "hm-njust"
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
