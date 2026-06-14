{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.zed-editor;
  zed-custom = pkgs.callPackage ./_package.nix {};

  basePackage =
    if cfg.useFHS
    then zed-custom.fhs
    else zed-custom.noFHS;

  zedPackage =
    if config.lib ? nixGL
    then config.lib.nixGL.wrap basePackage
    else basePackage;
in {
  options.features.zed-editor = {
    enable = lib.mkEnableOption "Zed-Preview high-performance code editor";
    useFHS = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Wrap Zed in a FHS environment for extension tooling compatibility.";
    };
  };
  config = lib.mkIf cfg.enable {
    programs.zed-editor = {
      enable = true;
      package = zedPackage;
    };
  };
}
