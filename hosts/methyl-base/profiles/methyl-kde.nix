{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ./. ["methyl-gaming"]
  ++ [{features = ["nixos-kde"];}]
)
