{
  config,
  lib,
  pkgs,
  ...
}: let
  scriptName = "lightsout";
  description = "OpenRGB lightsout support module";
in {
  options = {
    services."${scriptName}".enable = lib.mkEnableOption "Enable ${description}";
  };

  config = lib.mkIf config.services."${scriptName}".enable {
    services.udev.packages = [pkgs.openrgb];
    boot.kernelModules = lib.mkAfter ["i2c-dev"];
    boot.kernelParams = lib.mkAfter ["acpi_enforce_resources=lax"];
    hardware.i2c.enable = true;

    environment.systemPackages = with pkgs; [openrgb-with-all-plugins];
    services.hardware.openrgb.enable = true;
  };
}
