{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../. ["core" "base" "graphical"]
  ++ [{nixosModules = [../nixos-defaults.nix];}]
)
