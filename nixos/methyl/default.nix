{lib, ...}: {
  imports = [
    ./hardware-configuration.nix
    ./configuration.nix
    ./modules/nvidia.nix
    ./modules/veridian.nix
    ./modules/mounts.nix
    ./modules/gigabyte-sleepfix.nix
    ./modules/lightsout.nix
    ./modules/nvidia-pm
    ./modules/tweaks.nix
  ];
}
