{
  lib,
  config,
  ...
}: {
  config = {
    services = {
      xserver.enable = lib.mkIf config.flakeHost.isQemuVM true;
      displayManager.sddm = {
        enable = true;
        wayland.enable = lib.mkOverride 500 (!config.flakeHost.isQemuVM);
      };
      desktopManager.plasma6.enable = true;
      xserver.xkb = {
        layout = "us";
        variant = "";
      };
    };
  };
}
