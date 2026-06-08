{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.zed-editor;
  zed-custom = pkgs.callPackage ./_package.nix {};

  # apply nixGL wrapping only if the nixGL attribute is present
  zedPackage =
    if config.lib ? nixGL
    then config.lib.nixGL.wrap zed-custom.fhs
    else zed-custom.fhs;
in {
  options.features.zed-editor = {
    enable = lib.mkEnableOption "Zed-Preview high-performance code editor (FHS)";
  };

  config = lib.mkIf cfg.enable {
    programs.zed-editor = {
      enable = true;
      package = zedPackage;
    };
  };
}
