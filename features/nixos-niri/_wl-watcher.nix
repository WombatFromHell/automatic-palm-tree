{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.niri.wl-watcher;

  # Upstream tools, read through the flake package set (lib/default.nix injects
  # `flakePackages` for every input that exposes `packages`).
  watcherPkg = pkgs.flakePackages.beryl-utils.${pkgs.system}.default;
  gamemodePkg = pkgs.flakePackages.beryl-gamemode.${pkgs.system}.gamemode;

  # Mirrors upstream assets/units/wl-watcher/wl-watcher-uwsm.service: uwsm's
  # wayland-session@.target declares BindsTo/Before/PropagatesStopTo
  # =graphical-session.target, so following the per-compositor session target is
  # the compositor-agnostic wiring (no XDG_CURRENT_DESKTOP condition needed).
  sessionTargets = [
    "wayland-session@niri.desktop.target"
    "wayland-session@hyprland.desktop.target"
  ];

  # Store paths rather than upstream's `%h/.local/bin/gamemode` / `/usr/bin/pkill`:
  # systemd user units on Nix get no PATH into the store. The `-` prefix is the
  # systemd-native form of upstream's `|| true` (pkill exits 1 when nothing
  # matched, and Restart=on-failure would otherwise resurrect the watcher on stop).
  # Everything else -- poll interval, startup delay, relaxed/hold mode, app
  # filters -- is wl_watcher.py's upstream default.
  #
  # ponytail: wl_watcher.py shells out to bare `niri`, `pgrep`, `nvtop` from the
  # session PATH. On NixOS `niri` comes from features.niri's systemPackages
  # (nixos.nix:14); `pgrep`/`nvtop` are absent, and upstream degrades gracefully
  # (backend falls back to XDG_CURRENT_DESKTOP, GPU-strict filter falls back to
  # permissive). Upgrade path: add `pkgs.nvtopPackages.full` here if strict GPU
  # detection is ever wanted on the NixOS host.
  envVars = [
    "WATCHER_HOOK_ON=\"${gamemodePkg}/bin/gamemode on\""
    "WATCHER_HOOK_OFF=\"${gamemodePkg}/bin/gamemode off\""
  ];
in {
  options.features.niri.wl-watcher = {
    enable = lib.mkEnableOption "VRR/Fullscreen Wayland watcher (beryl-utils wl-watcher)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [watcherPkg gamemodePkg];

    systemd.user.services.wl-watcher = {
      Unit = {
        Description = "VRR/Fullscreen Monitor Events Watcher for Wayland";
        PartOf = sessionTargets;
        After = sessionTargets;
      };
      Install = {
        WantedBy = sessionTargets;
      };
      Service = {
        Type = "simple";
        # HYPRLAND_INSTANCE_SIGNATURE is a no-op under niri, and normally a no-op
        # under uwsm too -- defensive against a session manager that doesn't
        # propagate it (upstream comment, same reasoning).
        ExecStartPre = "${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE";
        ExecStart = "${watcherPkg}/bin/wl-watcher";
        Restart = "on-failure";
        RestartSec = "5";
        KillMode = "control-group";
        TimeoutStopSec = 5;
        ExecStop = "-${pkgs.procps}/bin/pkill -TERM -f gamemode";
        Environment = envVars;
      };
    };
  };
}
