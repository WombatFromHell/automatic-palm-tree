# Fixture: a host file that writes NixOS-module options instead of a host record.
# lib/hosts.nix must reject it with context pointing at lib/host-options.nix.
{hostLib, ...}: {
  system = "x86_64-linux";
  boot.loader.systemd-boot.enable = true;
}
