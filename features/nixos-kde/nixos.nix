{
  lib,
  config,
  ...
}: let
  # GDM owns the login screen once features.gnome is enabled; keep the KDE session for hosts without it.
  # ponytail: enabling nixos-gnome drops the Plasma session from the greeter (KDE apps remain).
  kdeLogin = !config.services.displayManager.gdm.enable;
in {
  config = {
    services = {
      xserver.enable = lib.mkIf config.flakeHost.isQemuVM true;
      displayManager.sddm = lib.mkIf kdeLogin {
        enable = true;
        wayland.enable = lib.mkOverride 500 (!config.flakeHost.isQemuVM);
      };
      desktopManager.plasma6.enable = lib.mkIf kdeLogin true;
      xserver.xkb = {
        layout = "us";
        variant = "";
      };
    };
  };
}
