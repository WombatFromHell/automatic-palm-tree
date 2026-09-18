{
  pkgsUnstable,
  lib,
  config,
  ...
}: let
  cfg = config.features.dms;
  dmsPkg = pkgsUnstable.dms-shell;
  quickshellPkg = pkgsUnstable.quickshell;
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
