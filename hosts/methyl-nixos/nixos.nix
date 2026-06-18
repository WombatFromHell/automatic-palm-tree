{ lib, ... }: {
  imports = [
    ../methyl/base.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = lib.mkForce "methyl-nixos";
}
