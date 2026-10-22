_: {
  # Everything we author lives on top of ./hardware-configuration.nix; nothing here
  # belongs in that generated file.
  boot = {
    loader = {
      systemd-boot.enable = true;
      # Apple's T2 firmware refuses EFI variable writes; systemd-boot writes its entries
      # straight to the ESP, so the loader still installs without efivars.
      efi.canTouchEfiVariables = false;
      timeout = 1;
    };
  };

  services = {
    openssh.enable = true;
  };

  features = {
    oomd.notify = true;
  };
}
