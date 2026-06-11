{
  pkgs,
  hostConfig,
  ...
}: {
  imports = [./hardware-configuration.nix];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      timeout = 1;
    };
    kernelPackages =
      if hostConfig.bootstrap
      then pkgs.linuxPackages_latest
      else pkgs.cachyosKernels.linuxPackages-cachyos-latest;
    kernelParams = [
      "kvm.ignore_msrs=1"
      "kvm.report_ignored_msrs=0"
    ];
  };
  networking.hostName = "methyl-nixos";

  services = {
    openssh.enable = true;
  };

  # for 'nixos-podman' feature enablement
  users.users.josh.extraGroups = ["podman"];

  features = {
    niri.enable = true;
    oomd.enable = true;
    korthos.enable = true;
    lsfg.enable = true;
  };
}
