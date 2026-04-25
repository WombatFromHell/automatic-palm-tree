{pkgs, ...}: {
  imports = [
    ../../home-manager
    ../../home-manager/dev.nix
    ../../home-manager/gpg.nix
  ];

  home.packages = with pkgs; [
    calcurse
    khal
    libqalculate
    trash-cli
    vdirsyncer
    yt-dlp
  ];

  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;
}
