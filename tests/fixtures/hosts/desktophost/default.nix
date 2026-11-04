# Fixture: a host asking for both desktop environments. The Plasma session is
# dropped by GDM, so the modules must say which session the greeter loses.
{hostLib, ...}: {
  system = "x86_64-linux";
  isNixOS = true;
  features = ["nixos-kde" "nixos-gnome"];
}
