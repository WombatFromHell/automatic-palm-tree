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

  # Mounts come from the layout in ./nixos.nix (ADR-eaca61b8), so this generated file keeps only
  # what is about the machine itself. The house convention is `nixos-generate-config
  # --no-filesystems`; regenerating with filesystems would collide with disko's `fileSystems`.
  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
