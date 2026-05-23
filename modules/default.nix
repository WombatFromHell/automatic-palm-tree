{self, ...}: {
  imports = [
    ./core
  ];

  flake.flakeModules = {
    nixos = self + /modules/nixos;
    home-manager = self + /modules/home-manager;
  };
}
