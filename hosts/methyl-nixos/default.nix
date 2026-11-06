{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-ws"]
  ++ [
    {
      # The VM's drive is NixOS's alone, which is the only thing that lets a gpt layout partition
      # it (features/nixos-disko/nixos.nix). methyl and propyl share theirs with Windows.
      ownsWholeDisk = true;
      features = [
        "nixos-cachyos"
        "nixos-btrfs"
        "nixos-disko"
        "nixos-qemu"
        "nixos-niri"
        "nixos-dms"
      ];
    }
  ]
)
