{
  lib,
  pkgs,
  config,
  ...
}: {
  # CachyOS kernels are only worth pulling from the cachix cache in the registry; never build
  # them locally as a fallback. `flakeCache.enable` is the gate, not a bootstrap flag.
  boot.kernelPackages = lib.mkIf (lib.elem "nix-community" config.flakeCache.enable && pkgs ? cachyosKernels) (
    lib.mkDefault pkgs.cachyosKernels.linux-cachyos-latest-lto-x86_64-v3
  );
}
