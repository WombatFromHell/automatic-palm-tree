{
  lib,
  config,
  pkgs,
  pkgsUnstable,
  ...
}: let
  cfg = config.features.dms;
  dmsPkg = pkgsUnstable.dms-shell;
  # dmsPkg = inputs.dms.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  options.features.dms = {
    enable = lib.mkEnableOption "DMS (Desktop Media Session) service";

    niriCompat = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add niri-specific service conditions (After=niri.service, XDG_CURRENT_DESKTOP=niri).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services."dms" = {
      Unit =
        {
          Description = "DMS Service";
          BindsTo = ["graphical-session.target"];
          After =
            ["graphical-session.target"]
            ++ lib.optionals cfg.niriCompat ["niri.service"];
          PartOf = ["graphical-session.target"];
        }
        // lib.optionalAttrs cfg.niriCompat {
          ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
        };
      Install = {
        WantedBy = ["graphical-session.target"];
      };
      Service = {
        Type = "dbus";
        BusName = "org.freedesktop.Notifications";
        ExecStart = "${dmsPkg}/bin/dms run --session";
        ExecReload = "${pkgs.procps}/bin/pkill -USR1 -x dms";
        Restart = "on-failure";
        RestartSec = "1.23";
        TimeoutStopSec = 10;
      };
    };
  };
}
