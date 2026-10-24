{hostLib, ...}:
hostLib.mergeModules (import ../methyl/default.nix {}) {
  features = [
    "nixos-btrfs"
    "nixos-gnome"
  ];
}
