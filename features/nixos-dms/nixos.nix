{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.dms;
  dmsPkg = pkgs.unstable.dms-shell;
  quickshellPkg = pkgs.unstable.quickshell;
in {
  options.features.dms = {
    enable = lib.mkEnableOption "DMS (Desktop Media Session) service" // {default = true;};
  };

  config = lib.mkIf cfg.enable {
    # DMS re-themes GTK/Qt/terminals from the wallpaper (matugen). It only
    # makes sense inside the niri UWSM session, which is the only session
    # whose env we scope; enabling it next to GNOME/KDE would clobber them.
    programs.dms-shell = {
      enable = true;
      package = dmsPkg;
      quickshell.package = quickshellPkg;
      # The package's own dms.service wants plain graphical-session.target,
      # which Plasma/GNOME also activate: systemd.packages still installs the
      # package units, but the generated unit is out of the picture and the
      # scoped unit below wantsBy the niri session target instead.
      systemd.enable = false;
      # Wallpaper-derived palettes are written to shared per-user files
      # (~/.config/gtk-3.0/gtk.css, ~/.config/gtk-4.0/gtk.css,
      # ~/.config/kdeglobals, ~/.config/matugen/templates/*) that the Plasma
      # and GNOME sessions also read. features/theming owns those via Nix, so
      # matugen stays off; flip to true to let wallpapers drive the theme.
      enableDynamicTheming = false;
    };

    systemd.user.services.dms = {
      description = "Dank Material Shell (DMS)";
      unitConfig = {
        PartOf = ["wayland-session@niri.desktop.target"];
        After = ["wayland-session@niri.desktop.target"];
      };
      wantedBy = ["wayland-session@niri.desktop.target"];
      serviceConfig = {
        # Upstream unit semantics: quickshell is Type=notify, not dbus/notifications.
        Type = "notify";
        NotifyAccess = "main";
        Environment = ["QS_DISABLE_CRASH_HANDLER=1"];
        ExecStart = "${dmsPkg}/bin/dms run --session";
        ExecReload = "${pkgs.procps}/bin/pkill -USR1 -x dms";
        Restart = "on-failure";
        RestartSec = "1.23";
        TimeoutStopSec = 10;
      };
    };

    assertions = [
      {
        assertion = config.features.niri.enable or false;
        message = "features.dms requires features.niri: DMS only runs in the niri UWSM session (wayland-session@niri.desktop.target). Set features.dms.enable = false to drop it.";
      }
    ];
  };
}
