{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ./. ["methyl-common"]
  ++ hostLib.profiles ../. ["gaming" "extras"]
)
