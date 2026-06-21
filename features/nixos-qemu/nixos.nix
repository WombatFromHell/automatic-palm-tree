{pkgsUnstable, ...}: {
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgsUnstable.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
      vhostUserPackages = [pkgsUnstable.virtiofsd];
      # Declarative OVMF/UEFI support
      # This replaces the manual ~/.config/libvirt/qemu.conf nvram edit
      ovmf = {
        enable = true;
        packages = [
          pkgsUnstable.OVMF.fd
          pkgsUnstable.AAVMF.fd
        ];
      };
    };
  };

  # add calling isAdmin-enabled users to our feature group
  extraGroups = ["libvirtd"];
  boot.extraModprobeConfig = "options kvm_intel kvm_amd nested=1";
}
