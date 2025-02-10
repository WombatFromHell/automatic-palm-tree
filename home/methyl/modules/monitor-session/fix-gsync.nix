{
  lib,
  pkgs,
  config,
  osConfig ? {},
  ...
}: let
  fixGsyncContent = builtins.readFile ./fix-gsync.py;
  unwrappedScript = pkgs.writeScriptBin "fix-gsync" fixGsyncContent;
  wrappedScript =
    pkgs.runCommand "wrapped-fix-gsync" {
      nativeBuildInputs = [pkgs.makeWrapper];
    } ''
      mkdir -p $out/bin
      makeWrapper ${unwrappedScript}/bin/fix-gsync $out/bin/fix-gsync \
        --prefix PATH : ${lib.makeBinPath [pkgs.python3 osConfig.hardware.nvidia.package.settings]}
    '';
in {
  config = lib.mkIf (osConfig.nvidia-support.enable or false) {
    home.packages = [wrappedScript];

    # make a symlink to our wrapped script in the live environment
    systemd.user.tmpfiles.rules = [
      "L+ %h/.local/bin/monitor-session/fix-gsync.py - - - - ${wrappedScript}/bin/fix-gsync"
    ];
  };
}
