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
    # Declaratively enable the system-level user unit provided by nixos.nix
    # by adding it to the graphical-session.target's wants list.
    systemd.user.targets.graphical-session.target.wants = [
      "oomd-notify.service"
    ];
  };
}
