{
  config,
  lib,
  ...
}: let
  moduleName = "swapfile";
  description = "local swapfile support";
in {
  options.${moduleName}.enable = lib.mkEnableOption "Enable ${description}";

  config = lib.mkIf config.${moduleName}.enable {
    swapDevices = [
      {
        device = "/mnt/linuxgames/Games/swapfile";
      }
    ];
  };
}
