{pkgs, ...}: {
  # include some custom ananicy-cpp rules
  services = {
    ananicy = {
      enable = true;
      package = pkgs.ananicy-cpp;
      rulesProvider = pkgs.ananicy-rules-cachyos;
      extraRules = [
        {
          "name" = "Dragon Age The Veilguard.exe";
          "type" = "Game";
        }
        {
          "name" = "TheGreatCircle.exe";
          "type" = "Game";
        }
      ];
    };

    # use kyber as the default ioscheduler
    udev.extraRules = ''
      ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="kyber"
      ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
      ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
    '';

    boot.kernel.sysctl = {
      # set sane swappiness behavior
      "vm.swappiness" = 1;
      "vm.watermark_boost_factor" = 0;
      "kernel.split_lock_mitigate" = 0;
    };
  };
}
