{
  config,
  osConfig ? {},
  lib,
  pkgs,
  ...
}: let
  scriptName = "lightsout";
  description = "OpenRGB lightsout profile service";
  scriptBin = pkgs.writeScriptBin "${scriptName}" ''
    #!${pkgs.stdenv.shell}

    OPENRGB="${pkgs.openrgb}/bin/openrgb"
    do_lightsout() {
      NUM_DEVICES=$("$OPENRGB" --noautoconnect --list-devices | grep -cE '^[0-9]+: ')

      for i in $(seq 0 $((NUM_DEVICES - 1))); do
        "$OPENRGB" --noautoconnect --device "$i" --mode static --color 000000
      done
    }

    # use a while case statement to handle arguments
    case "$1" in
    "--fallback")
      do_lightsout
      ;;
    *)
      "$OPENRGB" --noautoconnect -p lightsout
      ;;
    esac
  '';

  homeConfigModule = lib.mkIf config.services."${scriptName}".enable {
    assertions = [
      {
        assertion = osConfig.services.lightsout.enable or false;
        message = "The OpenRGB lightsout system module must be enabled in NixOS configuration";
      }
    ];

    systemd.user.services."${scriptName}" = {
      Unit = {
        Description = "${description}";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${scriptBin}/bin/${scriptName}";
      };
      Install = {
        WantedBy = ["default.target"];
      };
    };

    home.file.".config/OpenRGB/lightsout.orp" = {
      # turn off all RGB on DRAM, GPU, and mobo
      source = ./lightsout.orp;
    };

    # expose the script to the user's environment
    home.packages = [scriptBin];
  };

  monitorConfigModule = lib.mkIf config.services.monitor-session.enable {
    # expose a link to our script in the monitor-session script directory
    systemd.user.tmpfiles.rules = [
      "L+ %h/.local/bin/monitor-session/lightsout.sh - - - - ${scriptBin}/bin/lightsout"
    ];
  };
in {
  options = {
    services."${scriptName}".enable = lib.mkEnableOption "Enable the ${description}";
  };

  config = lib.mkMerge [homeConfigModule monitorConfigModule];
}
