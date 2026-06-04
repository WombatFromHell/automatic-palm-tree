# ./modules/features/nixos-oom/nixos.nix
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.features.oomd;
in {
  options.features.oomd = {
    enable = lib.mkEnableOption "systemd-oomd OOM killer";

    enableNotify = lib.mkOption {
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

    # ── Define the notify daemon globally if enabled ────────────────────────────
    environment.etc = lib.mkIf cfg.enableNotify {
      "systemd/user/oomd-notify.service" = {
        text = let
          oomd-notify-daemon = pkgs.writeShellApplication {
            name = "oomd-notify-daemon";
            runtimeInputs = with pkgs; [systemd coreutils libnotify];
            text = ''
              journalctl -u systemd-oomd -f --output=cat | while read -r line; do
                if echo "$line" | grep -q "Killed process"; then
                  proc=$(echo "$line" | grep -oP '(?<=Killed process ).*?(?= \()' || echo "Unknown Process")
                  notify-send -u critical "OOM Killer Active" "Process killed: $proc\nRAM/Swap pressure was too high."
                elif echo "$line" | grep -q "Pressures"; then
                  notify-send -u normal "Memory Pressure" "System is experiencing high memory pressure."
                fi
              done
            '';
          };
        in ''
          [Unit]
          Description=OOM Killer Desktop Notification Daemon
          BindsTo=graphical-session.target
          After=graphical-session.target
          PartOf=graphical-session.target

          [Service]
          Type=simple
          ExecStart=${oomd-notify-daemon}/bin/oomd-notify-daemon
          Restart=on-failure
          RestartSec=5

          [Install]
          WantedBy=graphical-session.target
        '';
      };
    };
  };
}
