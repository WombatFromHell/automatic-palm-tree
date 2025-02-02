{
  config,
  lib,
  pkgs,
  ...
}: let
  description = "Gigabyte USB wakeup trigger fix";
in {
  options = {
    services.sleepfix.enable = lib.mkEnableOption "${description}";
  };

  config = lib.mkIf config.services.sleepfix.enable {
    systemd.services.sleepfix = {
      description = "${description}";
      wantedBy = ["multi-user.target"];
      script = ''
        #!${pkgs.stdenv.shell}
        echo GP12 > /proc/acpi/wakeup
        echo GP13 > /proc/acpi/wakeup
        echo XHC0 > /proc/acpi/wakeup
        echo GPP0 > /proc/acpi/wakeup
        echo GPP8 > /proc/acpi/wakeup
        echo PTXH > /proc/acpi/wakeup
        echo PT24 > /proc/acpi/wakeup
        echo PT28 > /proc/acpi/wakeup
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };
    };
  };
}
