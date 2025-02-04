{pkgs, ...}: let
  moduleName = "veridian-controller";
  description = "Veridian Controller User Fan Service";
in {
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
      WantedBy = ["default.target"];
    };
  };
}
