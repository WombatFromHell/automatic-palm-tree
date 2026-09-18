{
  lib,
  config,
  pkgs,
  pkgsUnstable,
  ...
}: let
  cfg = config.features.lsfg;
  lsfgDeriv = pkgs.callPackage ./_package.nix {};
  lsfgPkg = [lsfgDeriv];
in {
  options.features.lsfg = {
    enable = lib.mkEnableOption "Korthos' Low-Latency Vulkan Layer" // {default = true;};
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lsfgPkg;
    hardware.graphics.extraPackages = lsfgPkg;
  };
}
