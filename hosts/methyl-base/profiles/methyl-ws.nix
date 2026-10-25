{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ./. ["methyl-common"]
  ++ [{features = ["nixos-gnome"];}]
)
