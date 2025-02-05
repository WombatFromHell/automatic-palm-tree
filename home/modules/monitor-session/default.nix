{
  lib,
  config,
  pkgs,
  ...
}: let
  moduleName = "monitor-session";
  description = "Lock/Unlock Script Event Functionality for KDE Plasma 6";

  monitorSession = import ./monitor-script.nix {inherit pkgs;};
  kscreenId = import ./kscreen-id.nix {inherit pkgs;};
in {
  options = {
    services."${moduleName}".enable = lib.mkEnableOption "Enable ${description}";
  };

  config = lib.mkIf config.services."${moduleName}".enable {
    systemd.user.services."${moduleName}" = {
      Unit = {
        Description = "${description}";
      };
      Service = {
        Type = "simple";
        ExecStart = "${monitorSession.monitorScript}/bin/monitor-dbus-session-state";
        ExecStop = "${pkgs.procps}/bin/pkill -9 -f monitor-dbus-session-state";
        RemainAfterExit = "yes";
      };
      Install = {
        WantedBy = ["graphical-session.target"];
      };
    };
    # expose 'kscreen-id' so the user's HM can use it
    home = {
      packages = [kscreenId];
    };
  };
}
