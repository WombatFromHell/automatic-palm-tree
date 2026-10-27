{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-kde"]
  ++ [{features = ["nixos-cachyos"];}]
)
