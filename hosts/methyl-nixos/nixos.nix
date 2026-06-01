{
  pkgs,
  hostConfig,
  ...
}: {
  imports = [./hardware-configuration.nix];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    # cachyos kernel only enabled if attr 'bootstrap = false;' set
    kernelPackages =
      if hostConfig.bootstrap
      then pkgs.linuxPackages_latest
      else pkgs.cachyosKernels.linuxPackages-cachyos-latest;
    extraKernelParams = [
      "kvm.ignore_msrs=1"
      "kvm.report_ignored_msrs=0"
    ];
  };
  networking.hostName = "methyl-nixos";

  # for debugging purposes
  services = {
    openssh.enable = true;
  };

  users.users.${hostConfig.username} = {
    isNormalUser = true;
    home = "/home/${hostConfig.username}";
    extraGroups = [
      "input"
      "lp"
      "networkmanager"
      "wheel"
    ];
  };
}
