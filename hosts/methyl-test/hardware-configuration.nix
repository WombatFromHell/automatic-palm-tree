{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd.availableKernelModules = ["ahci" "xhci_pci" "virtio_pci" "sr_mod" "virtio_blk"];
    initrd.kernelModules = [];
    kernelModules = ["kvm-amd"];
    extraModulePackages = [];
  };

  # Mounts come from the layout in ./nixos.nix, which terraform.sh reproduces from ./terraform.json
  # (ADR-b77ec913151f), so this generated file keeps only what is about the machine itself. The
  # house convention is `nixos-generate-config --no-filesystems`: regenerating with filesystems
  # would name partitions by UUID, which terraform.sh refuses to format (ADR-3d23b16441b6).
  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
