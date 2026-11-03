{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.yazi-fork;

  # The upstream wrapper is what adds the helper binaries yazi shells out to (fd, ripgrep,
  # ffmpeg, ...); swapping in the pinned fork build keeps that wrapper and HM's extraPackages.
  yazi-fork = pkgs.callPackage ./_package.nix {};
  yaziPackage = pkgs.unstable.yazi.override {yazi-unwrapped = yazi-fork;};
in {
  options.features.yazi-fork.enable =
    lib.mkEnableOption "yazi file manager built from the rylos/yazi fork"
    // {
      default = true;
    };

  config = lib.mkIf cfg.enable {
    programs.yazi = {
      enable = true;
      package = yaziPackage;
    };
    home.packages = [(lib.hiPrio yaziPackage)];
  };
}
