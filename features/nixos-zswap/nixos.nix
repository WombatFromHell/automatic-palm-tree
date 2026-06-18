_: {
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 4096; # Size in megabytes (4GB)
    }
  ];
  boot = {
    zswap = {
      enable = true;
      compressor = "zstd";
    };
    # throw in some highly recommended defaults
    kernel.sysctl = {
      # Aggressively favor zswap over dropping filesystem cache
      "vm.swappiness" = 150;
      # Prevent the kernel from aggressively reclaiming memory pages
      "vm.vfs_cache_pressure" = 50;
      # Keeps memory fragmentation low for zsmalloc
      "vm.watermark_boost_factor" = 0;
      "vm.watermark_scale_factor" = 125;
    };
  };
}
