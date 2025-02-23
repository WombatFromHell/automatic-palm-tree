{pkgs, ...}: {
  imports = [
    ./game-performance
    ./swapfile.nix
  ];

  game-performance.enable = true;
  swapfile.enable = true;

  boot.kernel.sysctl = {
    # set sane swappiness behavior
    "vm.swappiness" = 1;
    "vm.watermark_boost_factor" = 0;
    "kernel.split_lock_mitigate" = 0;
  };

  # use kyber as the default ioscheduler
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="kyber"
    ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
  '';
}
