{hostLib, ...}: {
  system = "x86_64-linux";
  # Derived facts are computed by lib/hosts.nix; a host file must not set them.
  name = "hijacked";
}
