# Fixture: a directory host that declares its own `homeModules.<user>`.
# Discovery must still add hosts/overridehost/home-josh.nix: merging with `//`
# used to drop it silently.
{hostLib, ...}: {
  system = "x86_64-linux";
  isNixOS = true;
  homeModules.josh = [./override.nix];
}
