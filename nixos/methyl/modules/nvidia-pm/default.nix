{
  config,
  lib,
  pkgs,
  ...
}: let
  moduleName = "nvidia-pm";
  description = "NVIDIA Power Limit Service";
  scriptName = "${moduleName}.py";
  scriptContent = builtins.readFile ./${scriptName};
  nvpmScript = pkgs.writeScriptBin "${scriptName}" scriptContent;
in {
  options = {
    services."${moduleName}".enable = lib.mkEnableOption "${description}";
  };

  config = lib.mkMerge [
    (lib.mkIf (config.nvidia-support.enable && config.services."${moduleName}".enable) {
      # write our config file
      environment.etc = {
        "${moduleName}.conf" = {
          text = ''
            BASE_PL=320
            LIMIT=0.72
          '';
          mode = "0640";
        };
      };

      systemd.services."${moduleName}" = {
        description = "NVIDIA Power Limit Service";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          Environment = "PATH=${config.hardware.nvidia.package.bin}/bin:${pkgs.python3}/bin";
          ExecStart = "${nvpmScript}/bin/${scriptName}";
          ExecStop = "${nvpmScript}/bin/${scriptName} undo";
          RemainAfterExit = "yes";
        };
      };

      systemd.timers."${moduleName}" = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = 5;
        };
      };
    })

    (lib.mkIf (!config.nvidia-support.enable && config.services."${moduleName}".enable) {
      warnings = [
        "The systemd unit 'nvidia-pm' is enabled but requires 'nvidia.enable' and cannot function without it!"
      ];
    })
  ];
}
