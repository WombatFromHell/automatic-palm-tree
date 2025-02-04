{
  config,
  lib,
  pkgs,
  ...
}: let
  scriptName = "nvidia-pm";
  description = "NVIDIA Power Limit Service";
  smiPath = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  scriptPath = pkgs.writeScriptBin "${scriptName}" ''
    #!${pkgs.bash}/bin/bash
    NVIDIASMI="${smiPath}"
    BC="${pkgs.bc}/bin/bc"
    AWK="${pkgs.gawk}/bin/awk"

    BASE_PL="320"

    do_math() {
      local math
      math="$1 * $2"
      echo "$math" | "$BC" | "$AWK" "{print int($1)}"
    }

    underclock() {
      "$NVIDIASMI" -pl "$1"
    }
    undo() {
      "$NVIDIASMI" -pl "$BASE_PL"
      "$NVIDIASMI" -rgc
      "$NVIDIASMI" -rmc
    }
    default() {
      limit="$(do_math $BASE_PL 0.72)" # 72%
      underclock "$limit"
    }

    "$NVIDIASMI" -pm 1
    [ "$1" != "undo" ] && undo

    if [ "$1" == "high" ]; then
      underclock "$BASE_PL"
    elif [ "$1" == "med" ]; then
      limit="$(do_math $BASE_PL 0.8)" # 80%
      underclock "$limit"
    elif [ "$1" == "low" ]; then
      default # 72%
    elif [ "$1" == "vlow" ]; then
      limit="$(do_math $BASE_PL 0.6)" # 60%
      underclock "$limit"
    elif [ "$1" == "xlow" ]; then
      limit="$(do_math $BASE_PL 0.4)" # 40%
      underclock "$limit"
    elif [ "$1" == "undo" ]; then
      undo
    else
      default
    fi
  '';
in {
  options = {
    services."${scriptName}".enable = lib.mkEnableOption "${description}";
  };

  config = lib.mkMerge [
    (lib.mkIf (config.nvidia-support.enable && config.services."${scriptName}".enable) {
      systemd.services."${scriptName}" = {
        description = "NVIDIA Power Limit Service";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${scriptPath}/bin/${scriptName} low";
          ExecStop = "${scriptPath}/bin/${scriptName} undo";
          RemainAfterExit = "yes";
        };
      };

      systemd.timers."${scriptName}" = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = 5;
        };
      };
    })

    (lib.mkIf (!config.nvidia-support.enable && config.services."${scriptName}".enable) {
      warnings = [
        "The systemd unit 'nvidiapm' is enabled but requires 'nvidia.enable', and will not function without it!"
      ];
    })
  ];
}
