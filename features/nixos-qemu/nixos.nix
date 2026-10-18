{pkgs, ...}: {
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.unstable.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
      vhostUserPackages = [pkgs.unstable.virtiofsd];
      # Declarative OVMF/UEFI support
      # This replaces the manual ~/.config/libvirt/qemu.conf nvram edit
      ovmf = {
        enable = true;
        packages = [
          pkgs.unstable.OVMF.fd
          pkgs.unstable.AAVMF.fd
        ];
      };
    };
  };

  # add calling isAdmin-enabled users to our feature group (attrset merges across features)
  extraGroups = {qemu = ["libvirtd"];};
  boot.extraModprobeConfig = "options kvm_intel kvm_amd nested=1";
}
