{hostLib, ...}: let
  myHome = {pkgs, ...}: {
    home.packages = with pkgs; [
      pkgs.unstable.yt-dlp
      pkgs.unstable.herdr
      trash-cli
    ];

    features = {
      tmux-git.enable = true;
    };
  };
in
  hostLib.mergeHome (
    hostLib.profiles ./methyl-base ["standalone"]
    ++ [
      {
        system = "x86_64-linux";
        homeModules.josh = [myHome];
      }
    ]
  )
