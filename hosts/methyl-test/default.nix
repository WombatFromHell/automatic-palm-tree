{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-minimal"]
  ++ [
    {
      ownsWholeDisk = true;
      features = ["nixos-qemu" "nixos-btrfs"];
    }
  ]
)
