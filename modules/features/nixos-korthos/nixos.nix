{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.features.korthos;
  lowLatencyLayer = pkgs.callPackage ./_package.nix {};
in {
  options.features.korthos = {
    enable = lib.mkEnableOption "Korthos' Low-Latency Vulkan Layer";
  };

  config = lib.mkIf cfg.enable {
    hardware.graphics.extraPackages = [
      lowLatencyLayer
    ];
  };
}
