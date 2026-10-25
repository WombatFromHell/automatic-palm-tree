{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../. ["core" "base" "graphical"]
  ++ [(hostLib.nixosModule ../nixos-defaults.nix)]
)
