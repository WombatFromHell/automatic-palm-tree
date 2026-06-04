{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.features.oomd;
in {
  options.features.oomd = {
    enable = lib.mkEnableOption "systemd-oomd OOM killer with userspace notify support";

    swapUsedLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "90%"; # Activate when swap hits 90%
      description = "Swap usage threshold to trigger early OOM actions (e.g. '90%' or '8G').";
    };

    memPressureLimit = lib.mkOption {
      type = lib.types.str;
      default = "60%"; # Activate when memory pressure hits 60%
      description = "Memory pressure threshold for cgroups (e.g. '60%').";
    };

    memPressureDuration = lib.mkOption {
      type = lib.types.str;
      default = "30s"; # Sustained pressure for 30s before acting
      description = "Duration memory pressure must be sustained before triggering a kill.";
    };

    enableNotify = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable userspace desktop notifications when OOM events occur.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── Userspace Notify Daemon ─────────────────────────────────────────────────
    # Monitors journalctl for systemd-oomd kills and pushes desktop notifications
    environment.systemPackages = lib.optionals cfg.enableNotify [
      (pkgs.writeShellApplication {
        name = "oomd-notify-daemon";
        runtimeInputs = with pkgs; [systemd coreutils libnotify];
        text = ''
          journalctl -u systemd-oomd -f --output=cat | while read -r line; do
            if echo "$line" | grep -q "Killed process"; then
              # Extract the process name roughly from the systemd-oomd log line
              proc=$(echo "$line" | grep -oP '(?<=Killed process ).*?(?= \()' || echo "Unknown Process")
              notify-send -u critical "OOM Killer Active" "Process killed: $proc\nRAM/Swap pressure was too high."
            elif echo "$line" | grep -q "Pressures"; then
              notify-send -u normal "Memory Pressure" "System is experiencing high memory pressure."
            fi
          done
        '';
      })
    ];

    # ── systemd-oomd Configuration ──────────────────────────────────────────────
    systemd = {
      oomd = {
        enable = true;

        # System-wide swap action
        enableRootSlice = true; # Monitor the root cgroup
        enableUserSlices = true; # Monitor user session cgroups

        # Configure thresholds for the system swap
        extraConfig = lib.mkIf (cfg.swapUsedLimit != null) {
          "SwapUsedLimit" = cfg.swapUsedLimit;
          "DefaultMemoryPressureDurationSec" = cfg.memPressureDuration;
        };
      };

      # Apply memory pressure monitoring specifically to user sessions
      # so apps get killed before the entire user.slice dies
      services = {
        "user@".serviceConfig = {
          ManagedOOMMemoryPressure = "kill";
          ManagedOOMMemoryPressureLimit = cfg.memPressureLimit;
          ManagedOOMMemoryPressureDurationSec = cfg.memPressureDuration;
          # Prevent critical desktop components from being killed first
          ManagedOOMPreference = "avoid";
        };
        # Protect the Display Manager (SDDM) from being killed
        display-manager.serviceConfig.ManagedOOMPreference = "omit";
      };

      # Run the notify daemon as a user service when the graphical session starts
      user.services.oomd-notify = lib.mkIf cfg.enableNotify {
        Unit = {
          Description = "OOM Killer Desktop Notification Daemon";
          BindsTo = ["graphical-session.target"];
          After = ["graphical-session.target"];
          PartOf = ["graphical-session.target"];
        };
        Install = {
          WantedBy = ["graphical-session.target"];
        };
        Service = {
          Type = "simple";
          ExecStart = "${pkgs.oomd-notify-daemon}/bin/oomd-notify-daemon";
          Restart = "on-failure";
          RestartSec = "5";
        };
      };
    };
  };
}
