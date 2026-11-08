{hostLib, ...}:
hostLib.mergeModules (
  hostLib.profiles ../. ["core" "base"]
  ++ [{nixosModules = [../nixos-defaults.nix];}]
)
