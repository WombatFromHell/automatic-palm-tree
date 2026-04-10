{lib, ...}: {
  imports = [
    ./modules/monitor-session
    ./modules/monitor-session/fix-gsync.nix
    ./modules/surround
    ./modules/openrgb
    ./modules/theming
    ./home.nix
  ];
}
