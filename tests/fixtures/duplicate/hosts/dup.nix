# Fixture: flat host record. Paired with dup/default.nix below, this is the
# duplicate-name case lib/hosts.nix must reject.
{hostLib, ...}: {system = "x86_64-linux";}
