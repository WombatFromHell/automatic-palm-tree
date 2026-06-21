{
  lib,
  config,
  hostConfig,
  pkgsUnstable,
  ...
}: let
  cfg = config.features.kde;
in {
  options.features.kde = {
    useUnstable = lib.mkEnableOption "Pull KDE packages from nixpkgs-unstable instead of stable";
  };

  config = {
    overlays = lib.mkIf cfg.useUnstable [
      (final: prev: {
        inherit (pkgsUnstable) kdePackages libsForQt5;
      })
    ];

    services = {
      xserver.enable = lib.mkIf hostConfig.isQemuVM true;
      displayManager.sddm = {
        enable = true;
        wayland.enable = lib.mkOverride 500 (!hostConfig.isQemuVM);
      };
      desktopManager.plasma6.enable = true;
      xserver.xkb = {
        layout = "us";
        variant = "";
      };
    };
  };
}
