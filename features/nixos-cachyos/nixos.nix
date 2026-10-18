{
  lib,
  pkgs,
  config,
  ...
}: {
  # ensure we only eval once the overlay exists - NEVER before
  boot.kernelPackages = lib.mkIf (!config.flakeHost.bootstrap && pkgs ? cachyosKernels) (
    lib.mkDefault pkgs.cachyosKernels.linux-cachyos-latest-lto-x86_64-v3
  );
}
