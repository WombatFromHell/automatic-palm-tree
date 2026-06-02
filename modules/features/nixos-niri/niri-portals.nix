{
  pkgs,
  lib,
  config,
  ...
}: let
  # Generate the portals.conf file in the Nix store
  niriPortalsConf = pkgs.writeTextDir "share/xdg-desktop-portal/niri-portals.conf" ''
    [preferred]
    org.freedesktop.impl.portal.Secret=kwallet;
    org.freedesktop.impl.portal.FileChooser=kde;
    org.freedesktop.impl.portal.Print=kde;
  '';
in {
  # Only enable this if the niri feature is also enabled
  config = lib.mkIf config.features.niri.enable {
    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-termfilechooser
        kdePackages.xdg-desktop-portal-kde
      ];
      # Tell NixOS which portals to prefer when XDG_CURRENT_DESKTOP=niri
      config.niri.default = lib.mkForce ["kde" "gtk"];
      configPackages = [niriPortalsConf];
    };
  };
}
