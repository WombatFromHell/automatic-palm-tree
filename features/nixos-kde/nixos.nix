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
      # kwin on Wayland: nixpkgs defaults sddm.wayland.enable to false, and SDDM asserts
      # xserver.enable || wayland.enable, so this line is what starts the session. X11 would be
      # needed only for a host without a GPU, which no host asks for today.
      displayManager.sddm = lib.mkIf kdeLogin {
        enable = true;
        wayland.enable = true;
      };
      desktopManager.plasma6.enable = lib.mkIf kdeLogin true;
      xserver.xkb = {
        layout = "us";
        variant = "";
      };
    };
  };
}
