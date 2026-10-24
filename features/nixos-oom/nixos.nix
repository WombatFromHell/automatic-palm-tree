{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.features.oomd;
in {
  options.features.oomd = {
    enable = lib.mkEnableOption "systemd-oomd OOM killer" // {default = true;};

    notify = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install the OOM userspace notify daemon.";
    };

    swapUsedLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "90%";
      description = "Swap usage threshold to trigger early OOM actions (e.g. '90%' or '8G').";
    };

    memPressureLimit = lib.mkOption {
      type = lib.types.str;
      default = "60%";
      description = "Memory pressure threshold for cgroups (e.g. '60%').";
    };

    memPressureDuration = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = "Duration memory pressure must be sustained before triggering a kill.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── systemd-oomd Configuration ──────────────────────────────────────────────
    systemd = {
      oomd = {
        enable = true;
        enableRootSlice = true;
        enableUserSlices = true;
        settings.OOM = lib.mkIf (cfg.swapUsedLimit != null) {
          "SwapUsedLimit" = cfg.swapUsedLimit;
          "DefaultMemoryPressureDurationSec" = cfg.memPressureDuration;
        };
      };

      services = {
        "user@".serviceConfig = {
          ManagedOOMMemoryPressure = "kill";
          ManagedOOMMemoryPressureLimit = cfg.memPressureLimit;
          ManagedOOMMemoryPressureDurationSec = cfg.memPressureDuration;
          ManagedOOMPreference = "avoid";
        };
        display-manager.serviceConfig.ManagedOOMPreference = "omit";
      };
    };

    # ── Notify daemon (user unit) ───────────────────────────────────────────────
    systemd.user.services.oomd-notify = lib.mkIf cfg.notify {
      description = "OOM Killer Desktop Notification Daemon";
      wantedBy = ["graphical-session.target"];
      partOf = ["graphical-session.target"];
      after = ["graphical-session.target"];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 5;
        ExecStart = lib.getExe (pkgs.writeShellApplication {
          name = "oomd-notify-daemon";
          runtimeInputs = with pkgs; [systemd coreutils gnugrep libnotify];
          text = ''
            journalctl -u systemd-oomd -f -n0 --output=cat | while read -r line; do
              case "$line" in
                Killed\ *)
                  notify-send -u critical "OOM Killer Active" "$line"
                  ;;
                *[Pp]ressure*)
                  notify-send -u normal "Memory Pressure" "High memory pressure detected."
                  ;;
              esac
            done
          '';
        });
      };
    };
  };
}
