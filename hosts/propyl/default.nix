{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../methyl-base/profiles ["methyl-common"]
  ++ [{features = ["nixos-kait2en"];}]
)
