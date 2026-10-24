{hostLib, ...}:
hostLib.mergeModules (import ../methyl-base/manifest.nix {}) {
  features = [
    "nixos-btrfs"
    "nixos-gnome"
  ];
}
