_: {
  ##
  # Bootstrap swapfile + zswap setup for initial NixOS rebuilds.
  #
  # This module uses only low-level options (boot.kernelParams) that are
  # available on **any** NixOS release, avoiding the higher-level
  # boot.zswap.* options which were added after nixos-25.11.
  #
  # Intended for the temporary /etc/nixos/swap-prepare.nix injected by
  # bootstrap.sh cmd_prepare_swap().  After a successful real rebuild from
  # the flake, this file is superseded by the flake's own swap config.
  #
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 4096; # 4 GiB
    }
  ];

  boot.kernelParams = [
    "zswap.enabled=1"
    "zswap.compressor=zstd"
  ];

  boot.kernel.sysctl = {
    # Aggressively favor zswap over dropping filesystem cache
    "vm.swappiness" = 150;
    # Prevent the kernel from aggressively reclaiming memory pages
    "vm.vfs_cache_pressure" = 50;
    # Keeps memory fragmentation low for zsmalloc
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
  };
}
