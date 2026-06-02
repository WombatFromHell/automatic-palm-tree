{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.kanshi;
in {
  options.features.kanshi = {
    enable = lib.mkEnableOption "Kanshi (display manager) service for niri";
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.kanshi = {
      Unit = {
        Description = "Kanshi Service";
        BindsTo = ["graphical-session.target"];
        After = ["graphical-session.target" "niri.service"];
        PartOf = ["graphical-session.target"];
        ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
      };
      Install = {
        WantedBy = ["graphical-session.target"];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.kanshi}/bin/kanshi";
        ExecReload = "${pkgs.procps}/bin/pkill --signal HUP -x kanshi";
        Restart = "on-failure";
        TimeoutStopSec = 10;
      };
    };
  };
}
