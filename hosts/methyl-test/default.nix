{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-ws"]
  ++ [
    {
      ownsWholeDisk = true;
      features = ["nixos-qemu"];
    }
  ]
)
