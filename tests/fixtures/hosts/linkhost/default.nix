# Fixture: a directory host whose module files are symlinks (a checkout where
# ./nixos.nix or home-*.nix points elsewhere). Discovery must load them, not skip them.
{hostLib, ...}: {
  system = "x86_64-linux";
  isNixOS = true;
}
