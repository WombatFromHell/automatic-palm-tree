{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.niri-watcher;

  niriBinPkg = pkgs.callPackage ./bin/niri-bin.nix {};

  envVars =
    [
      "WATCHER_HOOK_ON=\"${niriBinPkg}/bin/gamemode on\""
      "WATCHER_HOOK_OFF=\"${niriBinPkg}/bin/gamemode off\""
      "WATCHER_POLL_INTERVAL=${builtins.toString cfg.pollInterval}"
      "WATCHER_STARTUP_DELAY=${builtins.toString cfg.startupDelay}"
      "WATCHER_RELAXED_MODE=${lib.boolToString cfg.relaxedMode}"
      "WATCHER_HOLD_MODE=${lib.boolToString cfg.holdMode}"
    ]
    ++ lib.optionals (cfg.excludedApps != []) [
      "WATCHER_EXCLUDED_APPS=${lib.concatStringsSep ";" cfg.excludedApps}"
    ]
    ++ lib.optionals (cfg.includedApps != []) [
      "WATCHER_INCLUDED_APPS=${lib.concatStringsSep ";" cfg.includedApps}"
    ];
in {
  options.features.niri-watcher = {
    enable = lib.mkEnableOption "Niri VRR/Fullscreen Watcher service";

    pollInterval = lib.mkOption {
      type = lib.types.float;
      default = 2.0;
      description = "Poll interval in seconds for fullscreen detection.";
    };

    startupDelay = lib.mkOption {
      type = lib.types.float;
      default = 3.0;
      description = "Seconds to wait before first poll cycle.";
    };

    relaxedMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Detect all non-excluded apps without nvtop GPU check.";
    };

    holdMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Suppress HOOK_OFF while an included app's process is alive.";
    };

    excludedApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Semicolon-separated app filters to exclude from fullscreen detection.
        Format: app_id or app_id,title (title supports fnmatch globs).
        Examples: "ghostty;brave-browser,New Tab".
      '';
    };

    includedApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Semicolon-separated app filters to always detect as fullscreen
        (bypass nvtop GPU check). Highest priority.
        Format: app_id or app_id,title.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [niriBinPkg];

    systemd.user.services.niri-watcher = {
      Unit = {
        Description = "Niri VRR/Fullscreen Watcher";
        BindsTo = ["graphical-session.target"];
        After = ["graphical-session.target"];
        PartOf = ["graphical-session.target"];
        ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
      };
      Install = {
        WantedBy = ["graphical-session.target"];
      };
      Service = {
        Type = "simple";
        ExecStartPre = "${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY";
        ExecStart = "${niriBinPkg}/bin/niri_watcher.py";
        Restart = "on-failure";
        RestartSec = "5";
        KillMode = "control-group";
        TimeoutStopSec = 5;
        ExecStop = "${pkgs.procps}/bin/pkill -TERM -f 'gamemode' || true";
        Environment = envVars;
      };
    };
  };
}
