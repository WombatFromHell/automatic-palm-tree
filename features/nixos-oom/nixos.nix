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
      default = "75%";
      description = ''
        Fraction of swap that triggers systemd-oomd's swap rule. oomd.conf(5) fires it only when
        the fraction of RAM used *and* the fraction of swap used both exceed this value, and only on
        cgroups that declare ManagedOOMSwap=kill (set below). null drops the rule.
      '';
    };

    memPressureLimit = lib.mkOption {
      type = lib.types.str;
      default = "60%";
      description = "Memory pressure threshold for the monitored slices (e.g. '60%').";
    };

    memPressureDuration = lib.mkOption {
      type = lib.types.str;
      default = "15s";
      description = "Duration memory pressure must be sustained before triggering a kill.";
    };

    # Nothing in oomd bounds RAM usage: it reacts to PSI pressure and to swap fractions. The
    # ceiling that keeps a RAM hog from filling the machine is MemoryMax= on -.slice -- percentages
    # are relative to installed memory, so one default holds on a 32GB host and on a small VM.
    memoryHigh = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "93%";
      description = "Throttle band on -.slice: above this, reclaim is aggressive and pages spill to zswap.";
    };

    memoryMax = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "97%";
      description = "Hard RAM ceiling on -.slice; the kernel OOM killer runs inside the unit. null opts a host out.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── systemd-oomd Configuration ──────────────────────────────────────────────
    systemd = {
      oomd = {
        enable = true;
        enableRootSlice = true;
        enableUserSlices = true;
        settings.OOM = {
          SwapUsedLimit = lib.mkIf (cfg.swapUsedLimit != null) cfg.swapUsedLimit;
          DefaultMemoryPressureDurationSec = cfg.memPressureDuration;
        };
      };

      # systemd-oomd acts only on cgroups it was told to monitor, so the limits go on the slices
      # that carry the markers. On user.slice this also beats nixpkgs' mkDefault 80%.
      slices = {
        "-" = {
          sliceConfig = {
            ManagedOOMSwap = lib.mkIf (cfg.swapUsedLimit != null) "kill";
            MemoryHigh = lib.mkIf (cfg.memoryHigh != null) cfg.memoryHigh;
            MemoryMax = lib.mkIf (cfg.memoryMax != null) cfg.memoryMax;
          };
        };
        "user" = {
          sliceConfig = {
            ManagedOOMSwap = lib.mkIf (cfg.swapUsedLimit != null) "kill";
            ManagedOOMMemoryPressureLimit = cfg.memPressureLimit;
            ManagedOOMMemoryPressureDurationSec = cfg.memPressureDuration;
          };
        };
      };

      services = {
        # The session is where the RAM hog lives, so it is monitored, not de-prioritised.
        "user@".serviceConfig = {
          ManagedOOMMemoryPressure = "kill";
          ManagedOOMMemoryPressureLimit = cfg.memPressureLimit;
          ManagedOOMMemoryPressureDurationSec = cfg.memPressureDuration;
        };
        # omit keeps the session leader out of oomd's candidates; OOMScoreAdjust keeps it out of the
        # kernel kill MemoryMax= falls back to, which ignores ManagedOOMPreference.
        display-manager.serviceConfig = {
          ManagedOOMPreference = "omit";
          OOMScoreAdjust = -1000;
        };
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
