{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.dsh;
in {
  options.features.dsh.enable =
    lib.mkEnableOption "deepseek-harness (dsh) CLI, built from the pinned release tarball"
    // {
      default = true;
    };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.callPackage ./_package.nix {})
    ];
  };
}
