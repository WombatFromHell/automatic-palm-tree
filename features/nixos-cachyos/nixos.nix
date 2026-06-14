{
  lib,
  pkgs,
  inputs,
  hostConfig,
  ...
}: {
  # ensure we only eval once the overlay exists - NEVER before
  boot.kernelPackages = lib.mkIf (!hostConfig.bootstrap && pkgs ? cachyosKernels) (
    lib.mkDefault pkgs.cachyosKernels.linux-cachyos-latest-lto-x86_64-v3
  );
}
