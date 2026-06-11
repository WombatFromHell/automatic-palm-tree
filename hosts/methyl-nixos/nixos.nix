{
  pkgs,
  hostConfig,
  ...
}: let
  primaryUser = builtins.head hostConfig.usernames;
in {
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

  users.users.${primaryUser} = {
    isNormalUser = true;
    home = "/home/${primaryUser}";
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
    podman.enableUser = primaryUser;
  };
}
