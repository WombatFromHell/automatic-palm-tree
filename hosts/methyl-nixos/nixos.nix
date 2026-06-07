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
    # cachyos kernel only enabled if attr 'bootstrap = false;' set
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

  features = {
    niri.enable = true;
    oomd.enable = true;
    korthos.enable = true;
    lsfg.enable = true;
  };
}
