# Shape only — `nixos-generate-config` on the laptop overwrites this file.
# propyl-specific config lives in ./base.nix, never here.
# ponytail: confirm `sys_vendor`/`product_name` really say MacBookPro16,2 —
# features/nixos-kait2en defaults its knobs for that model.
{lib, ...}: {
  boot = {
    initrd.availableKernelModules = ["nvme" "xhci_pci" "usb_storage"];
    initrd.kernelModules = [];
    kernelModules = [];
    extraModulePackages = [];
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = ["fmask=0077" "dmask=0077"];
  };

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
