{
  lib,
  pkgs,
  config,
  ...
}: {
  # CachyOS kernels are only worth pulling from the cachix cache in the registry; never build
  # them locally as a fallback. `flakeCache.enable` is the gate, not a bootstrap flag.
  # `linuxPackages-…` is the kernel *package set* (boot.kernelPackages needs `extend`);
  # the bare `linux-…` name is the kernel derivation and fails in boot/kernel.nix.
  boot.kernelPackages = lib.mkIf (lib.elem "nix-community" config.flakeCache.enable && pkgs ? cachyosKernels) (
    lib.mkDefault pkgs.cachyosKernels.linuxPackages-cachyos-latest-lto-x86_64-v3
  );
}
