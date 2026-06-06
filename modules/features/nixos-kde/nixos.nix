{
  config,
  lib,
  ...
}: let
  cfg = config.features.kde;
  plasmaOverlay = import ./_overlay.nix;
in {
  # Define the configuration options for this module
  options.features.kde = {
    enable = lib.mkEnableOption "KDE Plasma 6 desktop environment";

    overlay.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the experimental plasma-workspace overlay to unify XDG_DATA_DIRS.";
    };
  };

  # Apply configuration based on the options enabled above
  config = lib.mkIf cfg.enable {
    # 1. Base KDE Desktop Settings
    services = {
      displayManager.sddm.enable = true;
      desktopManager.plasma6.enable = true;
      xserver.xkb = {
        layout = "us";
        variant = "";
      };
    };

    # 3. Optional plasma-workspace Overlay
    nixpkgs.overlays = lib.mkIf cfg.overlay.enable [
      (final: prev: plasmaOverlay {inherit final prev;})
    ];
  };
}
