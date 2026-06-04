_: {
  zramSwap = {
    enable = true;
    priority = 100;
    algorithm = "zstd";
    zram-size = "min(ram * 0.25, 4096)";
  };
}
