{lib, ...}: {
  zramSwap.enable = true;
  # Override the NixOS-generated settings with our own native zram-generator syntax
  services.zram-generator.settings = lib.mkForce {
    zram0 = {
      zram-size = "min(ram * 0.25, 4096)";
      compression-algorithm = "zstd";
      swap-priority = 100;
    };
  };
}
