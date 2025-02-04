{
  lib,
  pkgs,
  config,
  ...
}: let
  moduleName = "veridian-controller";
  description = "Veridian Controller User Fan Service";
in {
  options."${moduleName}".enable = lib.mkEnableOption "Enable ${description}";

  config = lib.mkIf config."${moduleName}".enable {
    home.packages = [pkgs.${moduleName}];

    systemd.user.services."${moduleName}" = {
      Unit = {
        Description = "${description}";
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.${moduleName}}/bin/${moduleName}";
        TimeoutStopSec = 10;
      };
      Install = {
        WantedBy = ["graphical-session.target"];
      };
    };
  };
}
