{
  lib,
  pkgs,
  osConfig ? {},
  ...
}: let
  fixGsyncContent = builtins.readFile ./fix-gsync.py;
  fixGsyncScript = pkgs.writeScriptBin "fix-gsync" fixGsyncContent;
in {
  config = lib.mkIf osConfig.nvidia-support.enable {
    # make a symlink to our script's store path
    systemd.user.tmpfiles.rules = [
      "L+ %h/.local/bin/monitor-session/fix-gsync.py - - - - ${fixGsyncScript}/bin/fix-gsync"
    ];
    # expose fix-gsync to pkgs
    home.packages = [fixGsyncScript];
  };
}
