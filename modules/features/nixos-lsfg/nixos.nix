{
  lib,
  config,
  pkgsUnstable,
  ...
}: let
  cfg = config.features.lsfg;
in {
  options.features.lsfg = {
    enable = lib.mkEnableOption "Korthos' Low-Latency Vulkan Layer";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgsUnstable; [
      lsfg-vk
      lsfg-vk-ui
    ];
    hardware.graphics.extraPackages = with pkgsUnstable; [lsfg-vk];
  };
}
