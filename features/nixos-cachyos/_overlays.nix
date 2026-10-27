{inputs, ...}: {
  config.nixpkgs.overlays = [inputs.nix-cachyos-kernel.overlays.pinned];
}
