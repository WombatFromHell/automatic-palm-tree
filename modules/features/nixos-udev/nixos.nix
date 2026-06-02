{lib, ...}: let
  customUdevRules = {
    "99-bluetooth-wakeup.rules" = ''
      # Enable wakeups from MediaTek Bluetooth Radio (MT7922)
      ACTION=="add|change", DRIVERS=="usb", SUBSYSTEM=="usb", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="0616", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"

      # '8bitdo Pro 2'
      ACTION=="add", SUBSYSTEM=="input", ATTRS{uniq}=="e4:17:d8:c9:a7:79", ATTR{power/wakeup}="enabled"
      # 'Pro Controller'
      ACTION=="add", SUBSYSTEM=="input", ATTRS{uniq}=="e4:17:d8:41:67:5c", ATTR{power/wakeup}="enabled"
    '';

    "99-disable-wakeup.rules" = ''
      # Disable Mouse wakeup
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1d57", ATTR{idProduct}=="fa60", ATTR{power/wakeup}="disabled"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1d57", ATTR{idProduct}=="fa61", ATTR{power/wakeup}="disabled"
      # Disable Keyboard wakeup
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0c45", ATTR{idProduct}=="8006", ATTR{power/wakeup}="disabled"
    '';

    "99-steam-controller-wakeup.rules" = ''
      # Enable wakeups from wireless Steam Controller
      ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="28de", ATTRS{idProduct}=="1142", ATTR{power/wakeup}="enabled"
    '';
  };
in {
  services.udev.extraRules = lib.concatStringsSep "\n\n" (lib.attrValues customUdevRules);
  system.activationScripts.udevReloadRules = lib.stringAfter ["etc"] ''
    echo "Reloading udev rules..."
    udevadm control --reload-rules || true
    udevadm trigger|| true
  '';
}
