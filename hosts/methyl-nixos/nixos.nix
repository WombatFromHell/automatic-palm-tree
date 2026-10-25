{...}: {
  imports = [./hardware-configuration.nix];

  services.openssh.enable = true;
  features.qemu.enable = false;
}
