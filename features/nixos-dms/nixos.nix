{
  pkgs,
  pkgsUnstable,
  lib,
  config,
  inputs,
  ...
}: let
  cfg = config.features.dms;
  dmsPkg = pkgsUnstable.dms-shell;
  # dmsPkg = inputs.dms.packages.${pkgs.stdenv.hostPlatform.system}.default;
  #
  quickshellPkg = pkgsUnstable.quickshell;
  # quickshellPkg = pkgs.quickshell;
in {
  options.features.dms = {
    enable = lib.mkEnableOption "DMS (Desktop Media Session) service";
  };

  config = lib.mkIf cfg.enable {
    programs.dms-shell = {
      enable = true;
      package = dmsPkg;
      quickshell.package = quickshellPkg;
    };
  };
}
