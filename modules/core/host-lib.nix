# Thin wrapper functions that tag a module with its target platform.
# Injected into every host file's arguments via discovery.nix.
# The module path can be a file or a directory containing default.nix.
{
  hmModule = module: {
    platform = "home";
    inherit module;
  };
  nixosModule = module: {
    platform = "nixos";
    inherit module;
  };
  sharedModule = module: {
    platform = "shared";
    inherit module;
  };
}
