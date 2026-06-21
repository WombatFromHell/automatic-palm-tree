{lib, ...}: {
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      timeout = 1;
    };
    kernelParams = [
      "kvm.ignore_msrs=1"
      "kvm.report_ignored_msrs=0"
    ];
  };
  networking.hostName = lib.mkDefault "methyl";

  services = {
    openssh.enable = true;
  };

  features = {
    # kde.useUnstable = true;
    niri.enable = true;
    dms.enable = true;
    oomd.enable = true;
    korthos.enable = true;
    lsfg.enable = true;
  };
}
