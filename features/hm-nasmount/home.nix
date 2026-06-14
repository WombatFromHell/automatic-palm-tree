{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.nasmount;
  nasmount-sshfs = pkgs.writeShellScriptBin "nasmount-sshfs" (builtins.readFile ./nasmount-sshfs.sh);
in {
  options.features.nasmount = {
    enable = lib.mkEnableOption "nasmount-sshfs: automount network share via sshfs on login";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.sshfs
      pkgs.fuse3
      nasmount-sshfs
    ];

    systemd.user.services.nasmount-sshfs = {
      Unit = {
        Description = "Automount network share via sshfs on login";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Install = {
        WantedBy = ["default.target"];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${nasmount-sshfs}/bin/nasmount-sshfs mount";
        ExecStop = "${nasmount-sshfs}/bin/nasmount-sshfs unmount";
        RemainAfterExit = true;
        TimeoutStopSec = 10;
      };
    };
  };
}
