{
  lib,
  pkgs,
  config,
  ...
}: let
  moduleName = "veridian-controller";
  description = "Veridian Controller User Fan Service";
in {
  options.services."${moduleName}".enable = lib.mkEnableOption "Enable ${description}";

  config = lib.mkIf config.services."${moduleName}".enable {
    environment.systemPackages = [pkgs.${moduleName}];

    systemd.services."${moduleName}" = {
      description = "${description}";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Environment = "PATH=/run/wrappers/bin:${config.hardware.nvidia.package.settings}/bin:${config.hardware.nvidia.package.bin}/bin";
        Type = "simple";
        ExecStart = "${pkgs.${moduleName}}/bin/${moduleName} -f /etc/veridian-controller.toml";
        TimeoutStopSec = 10;
      };
    };
  };
}
