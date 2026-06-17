{
  pkgs,
  pkgsUnstable,
  lib,
  config,
  inputs,
  hostConfig,
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
    # expose 'pkgs.quickshell' via overlay (only post-bootstrap)
    overlays =
      lib.optionals
      (!hostConfig.bootstrap && inputs ? quickshell)
      [inputs.quickshell.overlays.default];

    programs.dms-shell = {
      enable = true;
      package = dmsPkg;
      quickshell.package = quickshellPkg;
    };
  };
}
