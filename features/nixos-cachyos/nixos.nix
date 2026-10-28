{
  lib,
  pkgs,
  config,
  ...
}: {
  # CachyOS kernels are only worth pulling from the cachix cache in the registry; never build
  # them locally as a fallback. `flakeCache.enable` is the gate, not a bootstrap flag, and
  # `required` is what makes modules/caches.nix warn a host that disables that cache (the same
  # pair features/nixos-niri uses).
  # `linuxPackages-…` is the kernel *package set* (boot.kernelPackages needs `extend`);
  # the bare `linux-…` name is the kernel derivation and fails in boot/kernel.nix.
  flakeCache.required.nix-community = true;
  boot.kernelPackages = lib.mkIf (lib.elem "nix-community" config.flakeCache.enable && pkgs ? cachyosKernels) (
    lib.mkDefault pkgs.cachyosKernels.linuxPackages-cachyos-latest-lto-x86_64-v3
  );
}
