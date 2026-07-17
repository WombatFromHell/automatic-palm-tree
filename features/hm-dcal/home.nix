{
  config,
  pkgsUnstable,
  inputs,
  lib,
  ...
}: let
  dcalPkg = inputs.dcal.packages.${pkgsUnstable.system}.default;
  cfg = config.features.dcal;
in {
  options.features.dcal = {
    enableService = lib.mkEnableOption "DankCalendar background service for Niri";
  };

  config = {
    # Ensure the package is installed
    home.packages = [
      dcalPkg
    ];

    xdg.desktopEntries."com.danklinux.dankcalendar" = {
      name = "Dank Calendar";
      genericName = "Calendar";
      comment = "Local, Google, Microsoft, and CalDAV calendars for the dank desktop";
      # Points explicitly to the binary from the flake package
      exec = "${dcalPkg}/bin/dcal open %u";
      icon = "dankcalendar";
      terminal = false;
      categories = ["Office" "Calendar" "Qt"];
      mimeType = ["x-scheme-handler/webcal" "x-scheme-handler/webcals"];
      settings = {
        Keywords = "calendar;events;agenda;schedule;caldav;ical;subscribe;";
        StartupNotify = "true";
        StartupWMClass = "com.danklinux.dankcalendar";
        SingleMainWindow = "true";
      };
    };

    systemd.user.services.dank-calendar-niri = lib.mkIf cfg.enableService {
      Unit = {
        Description = "DankCalendar Service (Niri)";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target"];
        Requisite = ["graphical-session.target"];
      };

      Service = {
        Type = "simple";
        ExecCondition = "${pkgsUnstable.bash}/bin/sh -c '[ \"$XDG_CURRENT_DESKTOP\" = \"niri\" ]'";

        # Points directly to the binary inside the flake package
        ExecStart = "${dcalPkg}/bin/dcal";

        Restart = "on-failure";
        TimeoutStopSec = 10;
      };

      Install = {
        WantedBy = ["graphical-session.target"];
      };
    };
  };
}
