# Fixture: directory host resolving to the same name as hosts/dup.nix.
# lib/hosts.nix must report both sources, not pick one silently.
{hostLib, ...}: {system = "x86_64-linux";}
