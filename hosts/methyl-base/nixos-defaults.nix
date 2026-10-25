{lib, ...}: {
  boot = {
    loader = {
      systemd-boot.enable = lib.mkDefault true;
      efi.canTouchEfiVariables = lib.mkDefault true;
      timeout = lib.mkDefault 1;
    };
    kernelParams = [
      "kvm.ignore_msrs=1"
      "kvm.report_ignored_msrs=0"
    ];
  };
  networking = {
    networkmanager.enable = true;
  };
}
