{
  lib,
  config,
  ...
}: let
  # GDM owns the login screen once features.gnome is enabled; keep the KDE session for hosts without it.
  kdeLogin = !config.services.displayManager.gdm.enable;
in {
  config = {
    # The session is silently absent from the greeter, so say which one the host lost.
    warnings = lib.optionals (!kdeLogin) [
      "Host enables nixos-kde and nixos-gnome: GDM owns the login screen, so the Plasma session (services.desktopManager.plasma6) is dropped; KDE apps remain."
    ];
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
