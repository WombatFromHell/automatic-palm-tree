{
  lib,
  hostConfig,
  ...
}: {
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
}
