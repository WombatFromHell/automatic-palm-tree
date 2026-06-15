{
  pkgs,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.features.niri.enable {
    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-termfilechooser
        kdePackages.xdg-desktop-portal-kde
      ];
      config.niri = {
        default = ["kde" "gtk"];
        "org.freedesktop.impl.portal.Secret" = ["kwallet"];
        "org.freedesktop.impl.portal.FileChooser" = ["kde"];
        "org.freedesktop.impl.portal.Print" = ["kde"];
      };
    };
  };
}
