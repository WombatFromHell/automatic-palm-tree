{self, ...}: {
  imports = [
    # Injects your host builders into the flake output
    ./core
  ];

  # Use 'flake.flakeModules' so it persists on the final 'self' object
  flake.flakeModules = {
    darwin = self + /modules/darwin;
    nixos = self + /modules/nixos;
    home-manager = self + /modules/home-manager;
  };
}
