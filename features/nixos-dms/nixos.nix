{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.dms;
  dmsPkg = pkgs.unstable.dms-shell;
  quickshellPkg = pkgs.unstable.quickshell;
in {
  options.features.dms = {
    enable = lib.mkEnableOption "DMS (Desktop Media Session) service" // {default = true;};
  };

  config = lib.mkIf cfg.enable {
    programs.dms-shell = {
      enable = true;
      package = dmsPkg;
      quickshell.package = quickshellPkg;
    };
  };
}
