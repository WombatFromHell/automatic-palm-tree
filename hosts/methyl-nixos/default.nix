{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-ws"]
  ++ [
    {
      features = [
        "nixos-cachyos"
        "nixos-btrfs"
        "nixos-qemu"
        # "nixos-niri"
        # "nixos-dms"
      ];
    }
  ]
)
