# Fixture: directory host. hosts/dirhost/nixos.nix and hosts/dirhost/home-*.nix
# are discovered by lib/hosts.nix without being declared here.
{hostLib, ...}: {system = "x86_64-linux"; isNixOS = true;}
