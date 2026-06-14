# ./modules/features/nixos-oom/home.nix
{
  lib,
  config,
  ...
}: let
  cfg = config.features.oomd;
in {
  options.features.oomd = {
    notify = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable userspace desktop notifications when OOM events occur.";
    };
  };

  config = lib.mkIf cfg.notify {
    # Enable the system-level user unit provided by nixos.nix
    # by adding it to the graphical-session.target's wants list.
    # HM's systemd types for targets don't expose a flat `wants` list,
    # so we use an activation script to enable the externally-provided unit.
    home.activation.enableOomdNotify = lib.hm.dag.entryAfter ["writeBoundary"] ''
      systemctl --user enable --now oomd-notify.service || true
    '';
  };
}
