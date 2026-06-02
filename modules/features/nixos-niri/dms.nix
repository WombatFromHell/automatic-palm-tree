{
  lib,
  config,
  pkgs,
  pkgsUnstable,
  ...
}: let
  cfg = config.features.dms;
  dmsPkg = pkgsUnstable.dms-shell;
in {
  options.features.dms = {
    enable = lib.mkEnableOption "DMS (Desktop Media Session) service for niri";
  };

  config = lib.mkIf cfg.enable (
    lib.mkIf (config ? home.homeDirectory) {
      systemd.user.services."dms" = {
        Unit = {
          Description = "DMS Service";
          BindsTo = ["graphical-session.target"];
          After = ["graphical-session.target" "niri.service"];
          PartOf = ["graphical-session.target"];
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
    }
  );
}
